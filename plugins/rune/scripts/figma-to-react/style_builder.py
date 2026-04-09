"""Builder pattern for extracting CSS/Tailwind style properties from Figma nodes.

Provides a chainable ``StyleBuilder`` that accumulates CSS property values
from Figma Paint, Effect, and layout data. The builder's ``.build()`` method
returns a dict of raw CSS properties, which can then be passed to
``TailwindMapper`` for class name conversion.

Usage::

    from .style_builder import StyleBuilder

    props = (
        StyleBuilder()
        .fills(node.fills)
        .strokes(node.strokes)
        .effects(node.effects)
        .corner_radius(node.corner_radius, node.corner_radii)
        .opacity(node.opacity)
        .size(node.width, node.height)
        .padding(node.padding)
        .build()
    )
"""

from __future__ import annotations

import logging
import math
from typing import Any, Dict, List, Optional, Tuple

from figma_types import (
    Color,
    Effect,
    EffectType,
    Paint,
    PaintType,
)

logger = logging.getLogger(__name__)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _color_to_css(color: Color, opacity: float = 1.0) -> str:
    """Convert a Figma Color to a CSS color string.

    Args:
        color: Figma RGBA color (0.0-1.0 range).
        opacity: Additional opacity multiplier.

    Returns:
        CSS color string (hex or rgba).
    """
    effective_alpha = color.a * opacity
    if effective_alpha >= 0.999:
        return color.to_hex()
    r = max(0, min(255, round(color.r * 255)))
    g = max(0, min(255, round(color.g * 255)))
    b = max(0, min(255, round(color.b * 255)))
    return f"rgba({r}, {g}, {b}, {effective_alpha:.2f})"


def _named_direction(dx: float, dy: float) -> Optional[str]:
    """Return a CSS named gradient direction for common axis-aligned vectors.

    Args:
        dx: Horizontal component of gradient direction.
        dy: Vertical component of gradient direction.

    Returns:
        Named CSS direction string, or None for arbitrary angles.
    """
    if abs(dx) < 0.01 and dy > 0:
        return "to bottom"
    if abs(dx) < 0.01 and dy < 0:
        return "to top"
    if dx > 0 and abs(dy) < 0.01:
        return "to right"
    if dx < 0 and abs(dy) < 0.01:
        return "to left"
    if dx > 0 and dy > 0:
        return "to bottom right"
    if dx > 0 and dy < 0:
        return "to top right"
    if dx < 0 and dy > 0:
        return "to bottom left"
    if dx < 0 and dy < 0:
        return "to top left"
    return None


def _gradient_direction(positions: List[Any]) -> str:
    """Determine CSS gradient direction from Figma gradient handle positions.

    Args:
        positions: List of Vector2D-like objects with x, y attributes.

    Returns:
        CSS gradient direction string (e.g., "to right", "135deg").
    """
    if not positions or len(positions) < 2:
        return "to bottom"

    start = positions[0]
    end = positions[1]
    dx = getattr(end, "x", 0.0) - getattr(start, "x", 0.0)
    dy = getattr(end, "y", 0.0) - getattr(start, "y", 0.0)

    named = _named_direction(dx, dy)
    if named is not None:
        return named

    angle_rad = math.atan2(dy, dx)
    angle_deg = round(math.degrees(angle_rad) + 90) % 360
    return f"{angle_deg}deg"


def _conic_gradient_angle(positions: List[Any]) -> str:
    """Determine CSS conic-gradient starting angle from Figma handle positions.

    Args:
        positions: List of Vector2D-like objects with x, y attributes.

    Returns:
        CSS angle string (e.g., "0deg", "90deg").
    """
    if not positions or len(positions) < 2:
        return "0deg"

    start = positions[0]
    end = positions[1]
    dx = getattr(end, "x", 0.0) - getattr(start, "x", 0.0)
    dy = getattr(end, "y", 0.0) - getattr(start, "y", 0.0)
    angle_rad = math.atan2(dy, dx)
    angle_deg = round(math.degrees(angle_rad) + 90) % 360
    return f"{angle_deg}deg"


def _gradient_stops_css(stops: Optional[List[Any]]) -> Optional[str]:
    """Convert Figma gradient stops to CSS gradient color stops.

    Args:
        stops: List of ColorStop-like objects with position and color.

    Returns:
        CSS gradient stops string (e.g., "#ff0000 0%, #0000ff 100%"),
        or None if stops is empty.
    """
    if not stops:
        return None

    parts: List[str] = []
    for stop in stops:
        color = getattr(stop, "color", None)
        position = getattr(stop, "position", 0.0)
        if color:
            css_color = _color_to_css(color)
        else:
            css_color = "transparent"
        parts.append(f"{css_color} {round(position * 100)}%")
    return ", ".join(parts)


# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

_SCALE_MODE_MAP = {
    "FILL": "cover",
    "FIT": "contain",
    "CROP": "cover",
    "TILE": "auto",
}

_BLEND_MAP = {
    "MULTIPLY": "multiply",
    "SCREEN": "screen",
    "OVERLAY": "overlay",
    "DARKEN": "darken",
    "LIGHTEN": "lighten",
    "COLOR_DODGE": "color-dodge",
    "COLOR_BURN": "color-burn",
    "HARD_LIGHT": "hard-light",
    "SOFT_LIGHT": "soft-light",
    "DIFFERENCE": "difference",
    "EXCLUSION": "exclusion",
    "HUE": "hue",
    "SATURATION": "saturation",
    "COLOR": "color",
    "LUMINOSITY": "luminosity",
}


# ---------------------------------------------------------------------------
# StyleBuilder
# ---------------------------------------------------------------------------


class StyleBuilder:
    """Chainable builder for extracting CSS properties from Figma data.

    Accumulates raw CSS property values into an internal dict. Call
    ``.build()`` to retrieve the final properties dict.

    Each method returns ``self`` to enable fluent chaining.
    """

    def __init__(self) -> None:
        self._props: Dict[str, str] = {}

    def _apply_solid_fill(self, paint: Paint, is_text: bool) -> None:
        """Apply a SOLID fill paint to CSS props.

        Args:
            paint: Solid fill paint object.
            is_text: If True, maps to ``color``; otherwise ``background-color``.
        """
        if paint.color:
            css_prop = "color" if is_text else "background-color"
            self._props[css_prop] = _color_to_css(paint.color, paint.opacity)

    def _apply_gradient_fill(self, paint: Paint) -> None:
        """Apply a gradient fill paint to CSS props.

        Supports LINEAR, RADIAL, ANGULAR (conic), and DIAMOND gradients.
        Angular gradients map to CSS conic-gradient.
        Diamond gradients are approximated as conic-gradient (closest CSS equivalent).

        Args:
            paint: Gradient fill paint object.
        """
        stops = _gradient_stops_css(paint.gradient_stops)
        if stops is None:
            return
        if paint.type == PaintType.GRADIENT_LINEAR:
            direction = _gradient_direction(paint.gradient_handle_positions or [])
            self._props["background-image"] = f"linear-gradient({direction}, {stops})"
        elif paint.type == PaintType.GRADIENT_RADIAL:
            self._props["background-image"] = f"radial-gradient(circle, {stops})"
        elif paint.type == PaintType.GRADIENT_ANGULAR:
            # Angular → conic-gradient (native CSS equivalent)
            angle = _conic_gradient_angle(paint.gradient_handle_positions or [])
            self._props["background-image"] = f"conic-gradient(from {angle}, {stops})"
        elif paint.type == PaintType.GRADIENT_DIAMOND:
            # Diamond → radial-gradient approximation (no native CSS diamond gradient)
            logger.warning(
                "Diamond gradient approximated as radial-gradient"
            )
            self._props["background-image"] = f"radial-gradient(circle, {stops})"

    def _apply_image_fill(self, paint: Paint) -> None:
        """Apply an IMAGE fill paint to CSS props.

        Maps Figma scaleMode to CSS background-size:
        - FILL → cover (default)
        - FIT → contain
        - CROP → cover
        - TILE → auto + repeat

        Args:
            paint: Image fill paint object.
        """
        scale_mode = paint.scale_mode if paint.scale_mode else "FILL"
        self._props["background-size"] = _SCALE_MODE_MAP.get(scale_mode, "cover")
        self._props["background-position"] = "center"
        if scale_mode == "TILE":
            self._props["background-repeat"] = "repeat"
        elif scale_mode == "FIT":
            self._props["background-repeat"] = "no-repeat"
        if paint.image_ref:
            self._props["_image_ref"] = paint.image_ref

    def _resolve_solid_fill(self, paint: Paint, is_text: bool) -> None:
        """Dispatch a single paint to the appropriate fill handler.

        Args:
            paint: The single visible Figma paint.
            is_text: If True, map solid fills to ``color``.
        """
        if paint.type == PaintType.SOLID:
            self._apply_solid_fill(paint, is_text)
        elif paint.type in (
            PaintType.GRADIENT_LINEAR, PaintType.GRADIENT_RADIAL,
            PaintType.GRADIENT_ANGULAR, PaintType.GRADIENT_DIAMOND,
        ):
            self._apply_gradient_fill(paint)
        elif paint.type == PaintType.IMAGE:
            self._apply_image_fill(paint)

    def _resolve_gradient_fill(
        self, visible: List[Paint], is_text: bool
    ) -> None:
        """Stack multiple fills into CSS gradient layers.

        Iterates bottom-to-top (reversed Figma order). Solids become
        ``background-color``, gradients are comma-separated into
        ``background-image``, and images are dispatched individually.

        Args:
            visible: List of visible Figma paints (len >= 2).
            is_text: If True, map solid fills to ``color``.
        """
        gradient_layers: List[str] = []
        for paint in reversed(visible):  # bottom-to-top in Figma = CSS stacking order
            if paint.type == PaintType.SOLID:
                self._apply_solid_fill(paint, is_text)
            elif paint.type in (
                PaintType.GRADIENT_LINEAR, PaintType.GRADIENT_RADIAL,
                PaintType.GRADIENT_ANGULAR, PaintType.GRADIENT_DIAMOND,
            ):
                stops = _gradient_stops_css(paint.gradient_stops)
                if stops:
                    if paint.type == PaintType.GRADIENT_LINEAR:
                        direction = _gradient_direction(
                            paint.gradient_handle_positions or [],
                        )
                        gradient_layers.append(
                            f"linear-gradient({direction}, {stops})",
                        )
                    elif paint.type == PaintType.GRADIENT_RADIAL:
                        gradient_layers.append(
                            f"radial-gradient(circle, {stops})",
                        )
                    elif paint.type in (
                        PaintType.GRADIENT_ANGULAR,
                        PaintType.GRADIENT_DIAMOND,
                    ):
                        angle = _conic_gradient_angle(
                            paint.gradient_handle_positions or [],
                        )
                        gradient_layers.append(
                            f"conic-gradient(from {angle}, {stops})",
                        )
            elif paint.type == PaintType.IMAGE:
                self._apply_image_fill(paint)

        if gradient_layers:
            self._props["background-image"] = ", ".join(gradient_layers)

    def fills(self, paints: List[Paint], *, is_text: bool = False) -> StyleBuilder:
        """Extract background/fill properties from Figma paints.

        Processes only the first visible fill. Handles SOLID colors,
        linear/radial gradients, and IMAGE fills.

        For TEXT nodes (``is_text=True``), solid fills are mapped to
        ``color`` (CSS text color) instead of ``background-color``.
        This produces Tailwind ``text-*`` classes instead of ``bg-*``.

        Args:
            paints: List of Figma Paint objects (typically node.fills).
            is_text: If True, map solid fills to ``color`` instead of
                ``background-color``. Defaults to False.

        Returns:
            Self for chaining.
        """
        visible = [p for p in paints if p.visible]
        if not visible:
            return self

        # Multi-fill support: Figma layers fills bottom-to-top.
        # For single fills, use the simple path (most common case).
        # For multiple fills, stack gradients/images via comma-separated
        # background-image and use the topmost solid as background-color.
        if len(visible) == 1:
            self._resolve_solid_fill(visible[0], is_text)
        else:
            self._resolve_gradient_fill(visible, is_text)

        return self

    def strokes(
        self, paints: List[Paint], weight: float = 0.0,
        stroke_align: Optional[str] = None,
    ) -> StyleBuilder:
        """Extract border/stroke properties from Figma paints.

        Stroke alignment controls how the stroke is rendered:
        - CENTER (default): standard CSS border
        - INSIDE: uses outline with negative offset to render inside
        - OUTSIDE: uses outline to render outside the element

        Args:
            paints: List of Figma Paint objects (typically node.strokes).
            weight: Stroke weight in pixels.
            stroke_align: Figma stroke alignment (INSIDE, OUTSIDE, CENTER).

        Returns:
            Self for chaining.
        """
        visible = [p for p in paints if p.visible]
        if not visible or weight <= 0:
            return self

        paint = visible[0]
        color: Optional[str] = None
        if paint.type == PaintType.SOLID and paint.color:
            color = _color_to_css(paint.color, paint.opacity)
        elif paint.type in (PaintType.GRADIENT_LINEAR, PaintType.GRADIENT_RADIAL):
            # BACK-002: Gradient stroke fallback — CSS border-image not widely supported,
            # so we approximate with the first gradient stop color and log a warning.
            logger.warning(
                "Gradient stroke detected — CSS gradient borders not supported, "
                "falling back to first gradient stop color"
            )
            stops = paint.gradient_stops
            if stops and stops[0].color:
                color = _color_to_css(stops[0].color, paint.opacity)

        if color is None:
            return self

        if stroke_align == "INSIDE":
            self._props["outline-width"] = f"{weight}px"
            self._props["outline-color"] = color
            self._props["outline-style"] = "solid"
            self._props["outline-offset"] = f"-{weight}px"
        elif stroke_align == "OUTSIDE":
            self._props["outline-width"] = f"{weight}px"
            self._props["outline-color"] = color
            self._props["outline-style"] = "solid"
            self._props["outline-offset"] = "0px"
        else:
            # CENTER (default) — standard border
            self._props["border-width"] = f"{weight}px"
            self._props["border-color"] = color
            self._props["border-style"] = "solid"

        return self

    def effects(self, effect_list: List[Effect]) -> StyleBuilder:
        """Extract shadow and blur properties from Figma effects.

        Handles DROP_SHADOW, INNER_SHADOW, LAYER_BLUR, and BACKGROUND_BLUR.
        Multiple shadows of the same type are combined.

        Args:
            effect_list: List of Figma Effect objects.

        Returns:
            Self for chaining.
        """
        drop_shadows: List[str] = []
        inner_shadows: List[str] = []

        for effect in effect_list:
            if not effect.visible:
                continue

            if effect.type == EffectType.DROP_SHADOW:
                shadow = self._format_shadow(effect)
                if shadow:
                    drop_shadows.append(shadow)

            elif effect.type == EffectType.INNER_SHADOW:
                shadow = self._format_shadow(effect, inset=True)
                if shadow:
                    inner_shadows.append(shadow)

            elif effect.type == EffectType.LAYER_BLUR:
                self._props["filter"] = f"blur({effect.radius}px)"

            elif effect.type == EffectType.BACKGROUND_BLUR:
                self._props["backdrop-filter"] = f"blur({effect.radius}px)"

        all_shadows = drop_shadows + inner_shadows
        if all_shadows:
            self._props["box-shadow"] = ", ".join(all_shadows)

        return self

    def corner_radius(
        self,
        uniform: float = 0.0,
        per_corner: Optional[List[float]] = None,
    ) -> StyleBuilder:
        """Extract border-radius from Figma corner radius values.

        Args:
            uniform: Uniform corner radius (used if per_corner is None).
            per_corner: Per-corner radii [topLeft, topRight, bottomRight, bottomLeft].

        Returns:
            Self for chaining.
        """
        if per_corner and any(r > 0 for r in per_corner):
            radii = [f"{r}px" for r in per_corner]
            self._props["border-radius"] = " ".join(radii)
        elif uniform > 0:
            self._props["border-radius"] = f"{uniform}px"

        return self

    def opacity(self, value: float) -> StyleBuilder:
        """Set opacity if less than 1.0.

        Args:
            value: Opacity value (0.0-1.0).

        Returns:
            Self for chaining.
        """
        if value < 1.0:
            self._props["opacity"] = f"{value:.2f}"
        return self

    def size(
        self,
        width: float,
        height: float,
        sizing_h: Optional[str] = None,
        sizing_v: Optional[str] = None,
    ) -> StyleBuilder:
        """Set width and height properties.

        Respects Figma sizing modes -- FILL maps to 100%, HUG omits
        the dimension (auto-sizing), FIXED uses explicit pixel values.

        Args:
            width: Width in pixels.
            height: Height in pixels.
            sizing_h: Horizontal sizing mode (FIXED, HUG, FILL).
            sizing_v: Vertical sizing mode (FIXED, HUG, FILL).

        Returns:
            Self for chaining.
        """
        if sizing_h == "FILL":
            self._props["width"] = "100%"
        elif sizing_h != "HUG" and width > 0:
            self._props["width"] = f"{width}px"

        if sizing_v == "FILL":
            self._props["height"] = "100%"
        elif sizing_v != "HUG" and height > 0:
            self._props["height"] = f"{height}px"

        return self

    def padding(self, values: Tuple[float, float, float, float]) -> StyleBuilder:
        """Set padding with smart optimization.

        Optimizes padding notation:
        - All equal: ``p-N``
        - Horizontal + vertical equal: ``px-N py-M``
        - Otherwise: individual values

        Args:
            values: Padding as (top, right, bottom, left).

        Returns:
            Self for chaining.
        """
        top, right, bottom, left = values
        if all(v == 0 for v in values):
            return self

        if top == right == bottom == left:
            self._props["padding"] = f"{top}px"
        elif top == bottom and left == right:
            self._props["padding-x"] = f"{left}px"
            self._props["padding-y"] = f"{top}px"
        else:
            if top > 0:
                self._props["padding-top"] = f"{top}px"
            if right > 0:
                self._props["padding-right"] = f"{right}px"
            if bottom > 0:
                self._props["padding-bottom"] = f"{bottom}px"
            if left > 0:
                self._props["padding-left"] = f"{left}px"

        return self

    def gap(self, value: float) -> StyleBuilder:
        """Set flex gap.

        Args:
            value: Gap in pixels.

        Returns:
            Self for chaining.
        """
        if value > 0:
            self._props["gap"] = f"{value}px"
        return self

    def min_max(
        self,
        min_w: Optional[float] = None,
        max_w: Optional[float] = None,
        min_h: Optional[float] = None,
        max_h: Optional[float] = None,
    ) -> StyleBuilder:
        """Set min/max dimension constraints.

        Args:
            min_w: Minimum width in pixels.
            max_w: Maximum width in pixels.
            min_h: Minimum height in pixels.
            max_h: Maximum height in pixels.

        Returns:
            Self for chaining.
        """
        if min_w is not None and min_w > 0:
            self._props["min-width"] = f"{min_w}px"
        if max_w is not None and max_w > 0:
            self._props["max-width"] = f"{max_w}px"
        if min_h is not None and min_h > 0:
            self._props["min-height"] = f"{min_h}px"
        if max_h is not None and max_h > 0:
            self._props["max-height"] = f"{max_h}px"
        return self

    def overflow_hidden(self, clips: bool) -> StyleBuilder:
        """Set overflow: hidden when content is clipped.

        Args:
            clips: Whether the node clips its content.

        Returns:
            Self for chaining.
        """
        if clips:
            self._props["overflow"] = "hidden"
        return self

    def rotation(self, degrees: float) -> StyleBuilder:
        """Set rotation transform.

        Only emits if the rotation is non-zero. Uses CSS transform syntax
        that maps to Tailwind ``rotate-[Ndeg]`` classes.

        Args:
            degrees: Rotation in degrees (Figma uses counter-clockwise;
                CSS uses clockwise, so we negate).

        Returns:
            Self for chaining.
        """
        if abs(degrees) > 0.01:
            # Figma rotation is counter-clockwise, CSS is clockwise
            css_deg = -degrees
            self._props["transform"] = f"rotate({css_deg:.1f}deg)"
        return self

    def blend_mode(self, mode: Optional[str]) -> StyleBuilder:
        """Set blend mode.

        Maps Figma blend mode names to CSS ``mix-blend-mode`` values.

        Args:
            mode: Figma blend mode string (e.g., MULTIPLY, SCREEN).

        Returns:
            Self for chaining.
        """
        if not mode:
            return self
        css_val = _BLEND_MAP.get(mode)
        if css_val:
            self._props["mix-blend-mode"] = css_val
        return self

    @staticmethod
    def _match_custom_tokens(
        rgb: Tuple[int, int, int],
        token_map: Dict[str, str],
        tw_prefix: str,
        snap_distance: float,
    ) -> Optional[Dict[str, Any]]:
        """Match an RGB color against a custom token map.

        Iterates through the token map looking for the closest color match
        within the snap distance threshold. Token map values must be hex
        strings (e.g. ``"#7F56D9"``).

        Args:
            rgb: The RGB tuple (0-255) to match against.
            token_map: Mapping of token name to hex color string.
            tw_prefix: Tailwind prefix for the result (e.g. ``"bg"``).
            snap_distance: Maximum Euclidean RGB distance for a valid match.

        Returns:
            Match dict with ``token`` and ``distance`` keys if a match
            is found within snap distance, or None.
        """
        from tailwind_mapper import _parse_hex, _rgb_distance

        best_dist = float("inf")
        best_token_name = ""
        for token_name, hex_value in token_map.items():
            token_rgb = _parse_hex(hex_value)
            if token_rgb is None:
                continue
            dist = _rgb_distance(rgb, token_rgb)
            if dist < best_dist:
                best_dist = dist
                best_token_name = token_name

        if best_dist <= snap_distance and best_token_name:
            return {
                "token": f"{tw_prefix}-{best_token_name}",
                "distance": round(best_dist, 1),
            }
        return None

    def build_token_mapping(
        self,
        *,
        token_snap_distance: float = 20.0,
        project_tokens: Optional[Dict[str, str]] = None,
        library_tokens: Optional[Dict[str, str]] = None,
    ) -> Dict[str, Dict[str, Any]]:
        """Produce a mapping of CSS properties to their nearest design tokens.

        Uses a three-layer resolution cascade for color tokens:

        - **Layer 2 (Semantic)**: ``project_tokens`` — purpose aliases from
          the project's design system (e.g. ``{"brand-primary": "#7F56D9"}``).
          Checked first.
        - **Layer 3 (Component)**: ``library_tokens`` — UI library adapter
          tokens (e.g. ``{"brand-600": "#7F56D9"}``). Checked second.
        - **Fallback**: Tailwind palette snap — the existing 242-color palette
          match. Always available as safety net.

        Layer 1 (Primitive) values are the raw Figma colors already stored in
        ``self._props`` — they are the input to the resolution cascade.

        For non-color properties (font sizes, font weights, letter spacing,
        line height), the existing Tailwind-based mapping is used directly.

        The function remains a pure function — it does NOT read YAML files.
        The caller is responsible for loading token maps from
        ``design-system-profile.yaml`` or other sources.

        Args:
            token_snap_distance: Maximum distance for color snapping.
                Passed through to the internal color palette lookup.
                Defaults to 20.0 (matches Tailwind mapper default).
            project_tokens: Optional Layer 2 semantic token map. Keys are
                token names (e.g. ``"brand-primary"``), values are hex
                color strings (e.g. ``"#7F56D9"``). Checked before
                library_tokens and Tailwind fallback.
            library_tokens: Optional Layer 3 component token map. Keys are
                library token names (e.g. ``"brand-600"``), values are hex
                color strings. Checked after project_tokens but before
                Tailwind fallback.

        Returns:
            Dict keyed by semantic property name (e.g. ``"bg_color"``,
            ``"font_size"``) mapping to ``{"raw": ..., "token": ...,
            "distance": ..., "source": ...}`` dicts. The ``source`` field
            indicates which layer matched: ``"project"``, ``"library"``,
            or ``"tailwind"``.
        """
        from tailwind_mapper import (
            _parse_hex,
            _parse_rgba,
            _rgb_distance,
            _TW_COLORS,
            _FONT_SIZE_SCALE,
            snap_color,
            map_font_size,
            map_font_weight,
            map_letter_spacing,
            map_line_height,
        )

        mapping: Dict[str, Dict[str, Any]] = {}

        # --- Color tokens (three-layer resolution) ---
        color_props = {
            "bg_color": "background-color",
            "text_color": "color",
            "border_color": "border-color",
            "outline_color": "outline-color",
        }
        for token_key, css_key in color_props.items():
            raw = self._props.get(css_key)
            if raw is None:
                continue
            tw_prefix = {
                "bg_color": "bg",
                "text_color": "text",
                "border_color": "border",
                "outline_color": "outline",
            }[token_key]

            rgb = _parse_hex(raw) or _parse_rgba(raw)
            if rgb is None:
                mapping[token_key] = {
                    "raw": raw, "token": snap_color(raw, tw_prefix),
                    "distance": -1, "source": "tailwind",
                }
                continue

            # Layer 2: Semantic tokens (project design system)
            if project_tokens:
                match = self._match_custom_tokens(
                    rgb, project_tokens, tw_prefix, token_snap_distance,
                )
                if match is not None:
                    mapping[token_key] = {
                        "raw": raw, "token": match["token"],
                        "distance": match["distance"], "source": "project",
                    }
                    continue

            # Layer 3: Component tokens (library adapter)
            if library_tokens:
                match = self._match_custom_tokens(
                    rgb, library_tokens, tw_prefix, token_snap_distance,
                )
                if match is not None:
                    mapping[token_key] = {
                        "raw": raw, "token": match["token"],
                        "distance": match["distance"], "source": "library",
                    }
                    continue

            # Fallback: Tailwind palette snap (existing behavior)
            best_dist = float("inf")
            best_name = ""
            best_shade = 500
            for palette_name, shades in _TW_COLORS.items():
                for shade, palette_rgb in shades.items():
                    dist = _rgb_distance(rgb, palette_rgb)
                    if dist < best_dist:
                        best_dist = dist
                        best_name = palette_name
                        best_shade = shade

            if best_dist <= token_snap_distance:
                token = f"{tw_prefix}-{best_name}-{best_shade}"
            else:
                hex_color = f"#{rgb[0]:02x}{rgb[1]:02x}{rgb[2]:02x}"
                token = f"{tw_prefix}-[{hex_color}]"

            mapping[token_key] = {
                "raw": raw,
                "token": token,
                "distance": round(best_dist, 1),
                "source": "tailwind",
            }

        # --- Font size token ---
        for css_key in ("font-size",):
            raw = self._props.get(css_key)
            if raw is None:
                continue
            try:
                px = float(raw.replace("px", ""))
            except (ValueError, AttributeError):
                continue

            token = map_font_size(px)
            # Compute distance: 0 if exact match, else abs diff
            best_diff = float("inf")
            for _, scale_px in _FONT_SIZE_SCALE.items():
                diff = abs(px - scale_px)
                if diff < best_diff:
                    best_diff = diff
            mapping["font_size"] = {
                "raw": px, "token": token, "distance": round(best_diff, 1),
                "source": "tailwind",
            }

        # --- Font weight token ---
        for css_key in ("font-weight",):
            raw = self._props.get(css_key)
            if raw is None:
                continue
            try:
                weight = float(raw)
            except (ValueError, AttributeError):
                continue

            token = map_font_weight(weight)
            rounded = round(weight / 100) * 100
            rounded = max(100, min(900, rounded))
            dist = abs(weight - rounded)
            mapping["font_weight"] = {
                "raw": weight, "token": token, "distance": round(dist, 1),
                "source": "tailwind",
            }

        # --- Letter spacing token ---
        for css_key in ("letter-spacing",):
            raw = self._props.get(css_key)
            if raw is None:
                continue
            try:
                px = float(raw.replace("px", "").replace("em", ""))
            except (ValueError, AttributeError):
                continue

            token = map_letter_spacing(px)
            mapping["letter_spacing"] = {
                "raw": px, "token": token, "distance": 0,
                "source": "tailwind",
            }

        # --- Line height token ---
        font_size_raw = self._props.get("font-size")
        line_height_raw = self._props.get("line-height")
        if line_height_raw and font_size_raw:
            try:
                lh_px = float(line_height_raw.replace("px", ""))
                fs_px = float(font_size_raw.replace("px", ""))
            except (ValueError, AttributeError):
                pass
            else:
                token = map_line_height(lh_px, fs_px)
                mapping["line_height"] = {
                    "raw": lh_px, "token": token, "distance": 0,
                    "source": "tailwind",
                }

        return mapping

    def build(self) -> Dict[str, str]:
        """Return the accumulated CSS properties dict.

        Returns:
            Dict mapping CSS property names to their string values.
        """
        return dict(self._props)

    # -- Private helpers --

    @staticmethod
    def _format_shadow(effect: Effect, inset: bool = False) -> Optional[str]:
        """Format a shadow effect as a CSS box-shadow value.

        Args:
            effect: Shadow effect to format.
            inset: Whether this is an inset (inner) shadow.

        Returns:
            CSS box-shadow string, or None if color is missing.
        """
        if not effect.color:
            return None

        offset_x = effect.offset.x if effect.offset else 0.0
        offset_y = effect.offset.y if effect.offset else 0.0
        color = _color_to_css(effect.color)
        spread = effect.spread

        prefix = "inset " if inset else ""
        return (
            f"{prefix}{offset_x}px {offset_y}px {effect.radius}px "
            f"{spread}px {color}"
        )
