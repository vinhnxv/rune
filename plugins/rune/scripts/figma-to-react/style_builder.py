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
            logging.getLogger(__name__).warning(
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
        _SCALE_MODE_MAP = {
            "FILL": "cover",
            "FIT": "contain",
            "CROP": "cover",
            "TILE": "auto",
        }
        self._props["background-size"] = _SCALE_MODE_MAP.get(scale_mode, "cover")
        self._props["background-position"] = "center"
        if scale_mode == "TILE":
            self._props["background-repeat"] = "repeat"
        elif scale_mode == "FIT":
            self._props["background-repeat"] = "no-repeat"
        if paint.image_ref:
            self._props["_image_ref"] = paint.image_ref

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
            paint = visible[0]
            if paint.type == PaintType.SOLID:
                self._apply_solid_fill(paint, is_text)
            elif paint.type in (
                PaintType.GRADIENT_LINEAR, PaintType.GRADIENT_RADIAL,
                PaintType.GRADIENT_ANGULAR, PaintType.GRADIENT_DIAMOND,
            ):
                self._apply_gradient_fill(paint)
            elif paint.type == PaintType.IMAGE:
                self._apply_image_fill(paint)
        else:
            # Multi-fill: collect gradient layers and use last solid as bg-color
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
            # BACK-002: Gradient stroke fallback — use first stop color
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
        _BLEND_MAP: Dict[str, str] = {
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
        css_val = _BLEND_MAP.get(mode)
        if css_val:
            self._props["mix-blend-mode"] = css_val
        return self

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
