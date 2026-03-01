"""Image fill detection and handling for Figma-to-React conversion.

Detects image fills in Figma nodes and generates appropriate React
elements (``<img>`` tags or inline SVG placeholders). Works with the
Figma Images API to resolve image export URLs.

Usage::

    from .image_handler import ImageHandler

    handler = ImageHandler(image_urls={"hash123": "https://..."})
    element = handler.generate_image_element(ir_node)
"""

from __future__ import annotations

import re
from typing import Dict, List, Optional, Tuple

from figma_types import Paint, PaintType
from node_parser import FigmaIRNode

# SVG path data character whitelist — only SVG path command characters and numeric data.
# Blocks any attempt to inject HTML/JSX through malicious path strings.
_SVG_PATH_WHITELIST_RE = re.compile(r'[^\d\s.,+\-eEMmLlHhVvCcSsQqTtAaZz]')

# Safe fill value whitelist: CSS color keywords, hex colors, and url(#id) references.
# Prevents arbitrary string interpolation in SVG fill attributes.
_SAFE_FILL_RE = re.compile(r'^(currentColor|none|#[0-9a-fA-F]{3,8}|url\(#[a-zA-Z0-9_-]+\))$')


# ---------------------------------------------------------------------------
# Gradient helpers (module-level, no class state required)
# ---------------------------------------------------------------------------


def _sanitize_gradient_id(node_id: str) -> str:
    """Sanitize a Figma node ID for use as an SVG gradient element ID.

    Figma node IDs use the format '123:456' which is invalid for XML IDs.
    Replaces all non-alphanumeric (except underscore and hyphen) chars with '-'.

    Args:
        node_id: Raw Figma node ID string.

    Returns:
        Sanitized ID safe for SVG element id attributes.
    """
    return re.sub(r'[^a-zA-Z0-9_-]', '-', node_id)


def _generate_gradient_defs(node: FigmaIRNode, paint: Paint) -> str:
    """Generate an SVG <defs> block with a linear or radial gradient.

    Computes gradient coordinates from Figma's gradientHandlePositions,
    which are normalized (0.0-1.0) relative to the node bounding box.
    Radial gradient ry is computed from handles[2] when available for
    accurate elliptical shape; falls back to circular approximation (ry=rx).

    Args:
        node: IR node providing the bounding box dimensions.
        paint: A GRADIENT_LINEAR or GRADIENT_RADIAL Paint object.

    Returns:
        SVG <defs> XML string, or empty string if handles/stops are missing.
    """
    handles = paint.gradient_handle_positions
    stops = paint.gradient_stops
    if not handles or not stops:
        return ""

    safe_id = _sanitize_gradient_id(node.node_id)
    width = node.width if node.width > 0 else 1.0
    height = node.height if node.height > 0 else 1.0

    # Build stop elements
    stop_elements: List[str] = []
    for stop in stops:
        offset = f"{stop.position:.4f}"
        color = stop.color.to_hex() if stop.color else "#000000"
        alpha = stop.color.a if stop.color else 1.0
        stop_elements.append(
            f'    <stop offset="{offset}" stopColor="{color}" stopOpacity="{alpha:.4f}" />'
        )
    stops_xml = "\n".join(stop_elements)

    if paint.type == PaintType.GRADIENT_LINEAR:
        # handles[0] = start point, handles[1] = end point (normalized coords)
        x1 = handles[0].x * width
        y1 = handles[0].y * height
        x2 = handles[1].x * width
        y2 = handles[1].y * height
        return (
            f"  <defs>\n"
            f'    <linearGradient id="grad-{safe_id}" '
            f'x1="{x1:.2f}" y1="{y1:.2f}" x2="{x2:.2f}" y2="{y2:.2f}" '
            f'gradientUnits="userSpaceOnUse">\n'
            f"{stops_xml}\n"
            f"    </linearGradient>\n"
            f"  </defs>"
        )

    if paint.type == PaintType.GRADIENT_RADIAL:
        # handles[0] = center, handles[1] = x-radius edge, handles[2] = y-radius edge
        cx = handles[0].x * width
        cy = handles[0].y * height
        rx_vec_x = (handles[1].x - handles[0].x) * width
        rx_vec_y = (handles[1].y - handles[0].y) * height
        rx = (rx_vec_x ** 2 + rx_vec_y ** 2) ** 0.5
        if len(handles) >= 3:
            # Compute ry from handles[2] for accurate elliptical gradients
            ry_vec_x = (handles[2].x - handles[0].x) * width
            ry_vec_y = (handles[2].y - handles[0].y) * height
            ry = (ry_vec_x ** 2 + ry_vec_y ** 2) ** 0.5
        else:
            # Circular approximation when handles[2] is absent
            ry = rx
        return (
            f"  <defs>\n"
            f'    <radialGradient id="grad-{safe_id}" '
            f'cx="{cx:.2f}" cy="{cy:.2f}" rx="{rx:.2f}" ry="{ry:.2f}" '
            f'gradientUnits="userSpaceOnUse">\n'
            f"{stops_xml}\n"
            f"    </radialGradient>\n"
            f"  </defs>"
        )

    return ""


def _resolve_svg_fill(node: FigmaIRNode) -> Tuple[str, str]:
    """Resolve the SVG fill value for a non-icon SVG candidate node.

    Inspects the node's fills list and returns the first visible fill's
    SVG representation. For SOLID fills, returns a hex color. For
    GRADIENT_LINEAR/GRADIENT_RADIAL fills, returns defs XML and a url()
    reference. Icons always return currentColor regardless of fill type.

    Note: Only the first visible fill is used. Figma supports stacked fills
    for blending effects, but SVG path elements can only reference a single
    fill at a time without complex compositing (<feBlend> etc.).

    Args:
        node: IR node to resolve fill for.

    Returns:
        Tuple of (defs_xml, fill_value). defs_xml is an SVG <defs> block
        string (may be empty). fill_value is a safe CSS fill value string.
    """
    # Icons always use currentColor for theming compatibility
    if node.is_icon_candidate:
        return "", "currentColor"

    for fill in node.fills:
        if not fill.visible:
            continue

        if fill.type == PaintType.SOLID:
            if fill.color:
                return "", fill.color.to_hex()

        if fill.type in (PaintType.GRADIENT_LINEAR, PaintType.GRADIENT_RADIAL):
            defs_xml = _generate_gradient_defs(node, fill)
            if defs_xml:
                safe_id = _sanitize_gradient_id(node.node_id)
                fill_value = f"url(#grad-{safe_id})"
                # Validate fill_value matches safe pattern before interpolation (WS-7)
                if _SAFE_FILL_RE.match(fill_value):
                    return defs_xml, fill_value

    # Default: currentColor (inherits CSS color for flexibility)
    return "", "currentColor"


# ---------------------------------------------------------------------------
# Image handler
# ---------------------------------------------------------------------------


class ImageHandler:
    """Handles image fill detection and element generation.

    Maintains a mapping of Figma image reference hashes to resolved
    URLs (from the Figma Images API). Generates appropriate React
    elements for image-containing nodes.

    Args:
        image_urls: Dict mapping image ref hashes to resolved URLs.
    """

    def __init__(
        self,
        image_urls: Optional[Dict[str, str]] = None,
        svg_urls: Optional[Dict[str, str]] = None,
    ) -> None:
        self._image_urls: Dict[str, str] = image_urls or {}
        self._svg_urls: Dict[str, str] = svg_urls or {}

    def set_image_urls(self, urls: Dict[str, str]) -> None:
        """Update the image URL mapping.

        Args:
            urls: Dict mapping image ref hashes to resolved URLs.
        """
        self._image_urls.update(urls)

    def resolve_url(self, image_ref: str) -> str:
        """Resolve an image reference hash to a URL.

        Args:
            image_ref: Figma image reference hash.

        Returns:
            Resolved URL, or empty string if not found.
        """
        return self._image_urls.get(image_ref, "")

    def has_image(self, node: FigmaIRNode) -> bool:
        """Check if a node contains an image fill.

        Args:
            node: IR node to check.

        Returns:
            True if the node has an image fill or is an SVG candidate.
        """
        return node.has_image_fill or node.is_svg_candidate

    def generate_image_jsx(
        self,
        node: FigmaIRNode,
        classes: str = "",
        aria_attrs: Optional[Dict[str, str]] = None,
    ) -> str:
        """Generate JSX for an image-containing node.

        For image fills, generates an ``<img>`` tag with resolved URL.
        For SVG candidates (boolean ops, icons), generates an inline
        SVG placeholder.

        Args:
            node: IR node with image content.
            classes: Tailwind class string for the element.
            aria_attrs: Optional ARIA attributes dict (from ``--aria`` flag).

        Returns:
            JSX string for the image element.
        """
        class_attr = f' className="{classes}"' if classes else ""

        # Build extra ARIA attribute string
        extra_attrs = ""
        if aria_attrs:
            for key in sorted(aria_attrs.keys()):
                val = aria_attrs[key]
                extra_attrs += f' {key}="{val}"'

        if node.is_svg_candidate:
            return self._generate_svg_placeholder(node, class_attr + extra_attrs)

        if node.has_image_fill and node.image_ref:
            url = _sanitize_image_url(self.resolve_url(node.image_ref))
            if not url:
                return f'<div{class_attr} />'
            alt = _sanitize_alt_text(node.name)
            width = round(node.width) if node.width > 0 else ""
            height = round(node.height) if node.height > 0 else ""
            size_attrs = ""
            if width:
                size_attrs += f' width={{{width}}}'
            if height:
                size_attrs += f' height={{{height}}}'
            return (
                f'<img src="{url}" alt="{alt}"{class_attr}{size_attrs}{extra_attrs} />'
            )

        # Fallback: div with background image
        return f'<div{class_attr} />'

    def _generate_svg_placeholder(
        self,
        node: FigmaIRNode,
        class_attr: str,
    ) -> str:
        """Generate inline SVG for vector nodes.

        If ``node.fill_geometry`` or ``node.stroke_geometry`` contains path
        data from the Figma API, renders actual ``<path>`` elements. If a
        pre-exported SVG URL is available in ``self._svg_urls``, embeds it
        via an ``<img>`` tag. Otherwise falls back to a TODO placeholder.

        Args:
            node: SVG candidate IR node.
            class_attr: Pre-formatted className attribute string.

        Returns:
            JSX string with SVG element.
        """
        width = round(node.width) if node.width > 0 else 24
        height = round(node.height) if node.height > 0 else 24
        safe_name = _sanitize_alt_text(node.name)

        # Determine fill: resolve gradient or solid fill for non-icon SVGs (icons use currentColor)
        defs_xml, fill_value = _resolve_svg_fill(node)

        # Determine stroke color: prefer first visible stroke paint for non-icon SVGs
        stroke_color = "currentColor"
        if not node.is_icon_candidate and node.strokes:
            for stroke in node.strokes:
                if stroke.visible and stroke.color:
                    stroke_color = stroke.color.to_hex()
                    break

        # Render actual paths from fillGeometry and strokeGeometry when available
        if node.fill_geometry or node.stroke_geometry:
            paths: List[str] = []
            for geo in node.fill_geometry:
                path_data = _sanitize_svg_path(geo.get("path", ""))
                wind_rule = geo.get("windingRule", "NONZERO").lower()
                fill_rule = "evenodd" if wind_rule == "evenodd" else "nonzero"
                if path_data:
                    paths.append(
                        f'<path d="{path_data}" fillRule="{fill_rule}" fill="{fill_value}" />'
                    )
            for geo in node.stroke_geometry:
                path_data = _sanitize_svg_path(geo.get("path", ""))
                wind_rule = geo.get("windingRule", "NONZERO").lower()
                fill_rule = "evenodd" if wind_rule == "evenodd" else "nonzero"
                if path_data:
                    paths.append(
                        f'<path d="{path_data}" fillRule="{fill_rule}" fill="{stroke_color}" />'
                    )
            if paths:
                path_lines = "\n".join(f"  {p}" for p in paths)
                defs_section = f"\n{defs_xml}" if defs_xml else ""
                return (
                    f"<svg{class_attr} "
                    f'width="{width}" height="{height}" '
                    f'viewBox="0 0 {width} {height}" '
                    f'fill="none" xmlns="http://www.w3.org/2000/svg">'
                    f"{defs_section}\n"
                    f"{path_lines}\n"
                    f"</svg>"
                )

        # SVG export URL fallback: use pre-exported SVG from Figma Images API
        svg_url = self._svg_urls.get(node.node_id, "")
        if svg_url:
            safe_url = _sanitize_image_url(svg_url)
            if safe_url:
                # NOTE: SVG export URLs from Figma Images API expire after ~14 days.
                # Re-run figma_to_react() to refresh if the URL stops working.
                return (
                    f'<img src="{safe_url}" alt="{safe_name}"{class_attr} '
                    f'width={{{width}}} height={{{height}}} />'
                )

        # Fallback: TODO placeholder
        return (
            f"<svg{class_attr} "
            f'width="{width}" height="{height}" '
            f'viewBox="0 0 {width} {height}" '
            f'fill="none" xmlns="http://www.w3.org/2000/svg">\n'
            f"  {{/* TODO: SVG paths for {safe_name} */}}\n"
            f"</svg>"
        )


def collect_image_refs(node: FigmaIRNode) -> List[str]:
    """Collect all image reference hashes from a node tree.

    Traverses the IR tree and extracts unique image reference hashes
    that need to be resolved via the Figma Images API.

    Args:
        node: Root IR node.

    Returns:
        List of unique image reference hash strings.
    """
    return list(dict.fromkeys(_collect_refs_recursive(node)))  # Deduplicate while preserving order


def _collect_refs_recursive(node: FigmaIRNode):
    """Recursively yield image refs from the tree.

    Args:
        node: Current IR node.

    Yields:
        Image reference hash strings found in the subtree.
    """
    if node.image_ref:
        yield node.image_ref
    for child in node.children:
        yield from _collect_refs_recursive(child)


def _sanitize_image_url(url: str) -> str:
    """Sanitize an image URL for safe use in JSX src attributes.

    Args:
        url: Raw URL string to sanitize.

    Returns:
        Sanitized URL, or "about:blank" if the URL is unsafe.
    """
    if not url:
        return ""
    # SEC-AUDIT-004: Restrict to HTTPS only — Figma API always returns HTTPS URLs.
    # Allowing http:// would create mixed content risk in deployed React apps.
    if not url.startswith("https://"):
        return "about:blank"
    return url.replace('"', "%22")


def _sanitize_svg_path(d: str) -> str:
    """Sanitize an SVG path data string using a character whitelist.

    Strips any character not in the SVG path command alphabet or numeric
    data to prevent XSS or injection through malicious path strings from
    the Figma API.

    Args:
        d: Raw SVG path data string.

    Returns:
        Sanitized path data string (whitelist characters only).
    """
    return _SVG_PATH_WHITELIST_RE.sub("", d)


def _sanitize_alt_text(name: str) -> str:
    """Sanitize a Figma node name for use as alt text.

    Removes quotes and special characters that could break JSX attributes.
    Also strips null bytes and ASCII control characters (WS-6).

    Args:
        name: Raw Figma node name.

    Returns:
        Sanitized alt text string.
    """
    # Strip null bytes and ASCII control characters (0x00-0x1F, 0x7F)
    name = re.sub(r'[\x00-\x1f\x7f]', '', name)
    return name.replace('"', "").replace("'", "").replace("<", "").replace(">", "").strip()
