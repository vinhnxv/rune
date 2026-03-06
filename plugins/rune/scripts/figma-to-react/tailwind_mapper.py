"""Tailwind CSS v4 class mapper for Figma design properties.

Maps raw CSS property values (from ``StyleBuilder``) to Tailwind v4
utility classes. Covers colors, spacing, typography, borders, shadows,
and opacity.

Tailwind v4 naming conventions used:
- ``rounded-xs`` (2px), ``shadow-xs``, ``blur-xs``
- ``bg-linear-to-*`` (not ``bg-gradient-to-*``)
- Any numeric spacing value supported (``p-3.5``, ``gap-2.5``)

Usage::

    from .tailwind_mapper import TailwindMapper

    mapper = TailwindMapper()
    classes = mapper.map_properties(style_builder.build())
    class_string = " ".join(classes)
"""

from __future__ import annotations

import math
import re
from typing import Dict, List, Optional, Tuple


# ---------------------------------------------------------------------------
# Tailwind v4 color palette
# ---------------------------------------------------------------------------

# 22 palettes x 11 shades (50-950) -- RGB tuples
# Subset of the most common palettes for distance matching
_TW_COLORS: Dict[str, Dict[int, Tuple[int, int, int]]] = {
    "slate": {
        50: (248, 250, 252), 100: (241, 245, 249), 200: (226, 232, 240),
        300: (203, 213, 225), 400: (148, 163, 184), 500: (100, 116, 139),
        600: (71, 85, 105), 700: (51, 65, 85), 800: (30, 41, 59),
        900: (15, 23, 42), 950: (2, 6, 23),
    },
    "gray": {
        50: (249, 250, 251), 100: (243, 244, 246), 200: (229, 231, 235),
        300: (209, 213, 219), 400: (156, 163, 175), 500: (107, 114, 128),
        600: (75, 85, 99), 700: (55, 65, 81), 800: (31, 41, 55),
        900: (17, 24, 39), 950: (3, 7, 18),
    },
    "red": {
        50: (254, 242, 242), 100: (254, 226, 226), 200: (254, 202, 202),
        300: (252, 165, 165), 400: (248, 113, 113), 500: (239, 68, 68),
        600: (220, 38, 38), 700: (185, 28, 28), 800: (153, 27, 27),
        900: (127, 29, 29), 950: (69, 10, 10),
    },
    "orange": {
        50: (255, 247, 237), 100: (255, 237, 213), 200: (254, 215, 170),
        300: (253, 186, 116), 400: (251, 146, 60), 500: (249, 115, 22),
        600: (234, 88, 12), 700: (194, 65, 12), 800: (154, 52, 18),
        900: (124, 45, 18), 950: (67, 20, 7),
    },
    "yellow": {
        50: (254, 252, 232), 100: (254, 249, 195), 200: (254, 240, 138),
        300: (253, 224, 71), 400: (250, 204, 21), 500: (234, 179, 8),
        600: (202, 138, 4), 700: (161, 98, 7), 800: (133, 77, 14),
        900: (113, 63, 18), 950: (66, 32, 6),
    },
    "green": {
        50: (240, 253, 244), 100: (220, 252, 231), 200: (187, 247, 208),
        300: (134, 239, 172), 400: (74, 222, 128), 500: (34, 197, 94),
        600: (22, 163, 74), 700: (21, 128, 61), 800: (22, 101, 52),
        900: (20, 83, 45), 950: (5, 46, 22),
    },
    "blue": {
        50: (239, 246, 255), 100: (219, 234, 254), 200: (191, 219, 254),
        300: (147, 197, 253), 400: (96, 165, 250), 500: (59, 130, 246),
        600: (37, 99, 235), 700: (29, 78, 216), 800: (30, 64, 175),
        900: (30, 58, 138), 950: (23, 37, 84),
    },
    "indigo": {
        50: (238, 242, 255), 100: (224, 231, 255), 200: (199, 210, 254),
        300: (165, 180, 252), 400: (129, 140, 248), 500: (99, 102, 241),
        600: (79, 70, 229), 700: (67, 56, 202), 800: (55, 48, 163),
        900: (49, 46, 129), 950: (30, 27, 75),
    },
    "purple": {
        50: (250, 245, 255), 100: (243, 232, 255), 200: (233, 213, 255),
        300: (216, 180, 254), 400: (192, 132, 252), 500: (168, 85, 247),
        600: (147, 51, 234), 700: (126, 34, 206), 800: (107, 33, 168),
        900: (88, 28, 135), 950: (59, 7, 100),
    },
    "pink": {
        50: (253, 242, 248), 100: (252, 231, 243), 200: (251, 207, 232),
        300: (249, 168, 212), 400: (244, 114, 182), 500: (236, 72, 153),
        600: (219, 39, 119), 700: (190, 24, 93), 800: (157, 23, 77),
        900: (131, 24, 67), 950: (80, 7, 36),
    },
    "teal": {
        50: (240, 253, 250), 100: (204, 251, 241), 200: (153, 246, 228),
        300: (94, 234, 212), 400: (45, 212, 191), 500: (20, 184, 166),
        600: (13, 148, 136), 700: (15, 118, 110), 800: (17, 94, 89),
        900: (19, 78, 74), 950: (4, 47, 46),
    },
    "cyan": {
        50: (236, 254, 255), 100: (207, 250, 254), 200: (165, 243, 252),
        300: (103, 232, 249), 400: (34, 211, 238), 500: (6, 182, 212),
        600: (8, 145, 178), 700: (14, 116, 144), 800: (21, 94, 117),
        900: (22, 78, 99), 950: (8, 51, 68),
    },
    "emerald": {
        50: (236, 253, 245), 100: (209, 250, 229), 200: (167, 243, 208),
        300: (110, 231, 183), 400: (52, 211, 153), 500: (16, 185, 129),
        600: (5, 150, 105), 700: (4, 120, 87), 800: (6, 95, 70),
        900: (6, 78, 59), 950: (2, 44, 34),
    },
    "violet": {
        50: (245, 243, 255), 100: (237, 233, 254), 200: (221, 214, 254),
        300: (196, 181, 253), 400: (167, 139, 250), 500: (139, 92, 246),
        600: (124, 58, 237), 700: (109, 40, 217), 800: (91, 33, 182),
        900: (76, 29, 149), 950: (46, 16, 101),
    },
    "rose": {
        50: (255, 241, 242), 100: (255, 228, 230), 200: (254, 205, 211),
        300: (253, 164, 175), 400: (251, 113, 133), 500: (244, 63, 94),
        600: (225, 29, 72), 700: (190, 18, 60), 800: (159, 18, 57),
        900: (136, 19, 55), 950: (76, 5, 25),
    },
    "amber": {
        50: (255, 251, 235), 100: (254, 243, 199), 200: (253, 230, 138),
        300: (252, 211, 77), 400: (251, 191, 36), 500: (245, 158, 11),
        600: (217, 119, 6), 700: (180, 83, 9), 800: (146, 64, 14),
        900: (120, 53, 15), 950: (69, 26, 3),
    },
    "lime": {
        50: (247, 254, 231), 100: (236, 252, 203), 200: (217, 249, 157),
        300: (190, 242, 100), 400: (163, 230, 53), 500: (132, 204, 22),
        600: (101, 163, 13), 700: (77, 124, 15), 800: (63, 98, 18),
        900: (54, 83, 20), 950: (26, 46, 5),
    },
    "sky": {
        50: (240, 249, 255), 100: (224, 242, 254), 200: (186, 230, 253),
        300: (125, 211, 252), 400: (56, 189, 248), 500: (14, 165, 233),
        600: (2, 132, 199), 700: (3, 105, 161), 800: (7, 89, 133),
        900: (12, 74, 110), 950: (8, 47, 73),
    },
    "fuchsia": {
        50: (253, 244, 255), 100: (250, 232, 255), 200: (245, 208, 254),
        300: (240, 171, 252), 400: (232, 121, 249), 500: (217, 70, 239),
        600: (192, 38, 211), 700: (162, 28, 175), 800: (134, 25, 143),
        900: (112, 26, 117), 950: (74, 4, 78),
    },
    "stone": {
        50: (250, 250, 249), 100: (245, 245, 244), 200: (231, 229, 228),
        300: (214, 211, 209), 400: (168, 162, 158), 500: (120, 113, 108),
        600: (87, 83, 78), 700: (68, 64, 60), 800: (41, 37, 36),
        900: (28, 25, 23), 950: (12, 10, 9),
    },
    "zinc": {
        50: (250, 250, 250), 100: (244, 244, 245), 200: (228, 228, 231),
        300: (212, 212, 216), 400: (161, 161, 170), 500: (113, 113, 122),
        600: (82, 82, 91), 700: (63, 63, 70), 800: (39, 39, 42),
        900: (24, 24, 27), 950: (9, 9, 11),
    },
    "neutral": {
        50: (250, 250, 250), 100: (245, 245, 245), 200: (229, 229, 229),
        300: (212, 212, 212), 400: (163, 163, 163), 500: (115, 115, 115),
        600: (82, 82, 82), 700: (64, 64, 64), 800: (38, 38, 38),
        900: (23, 23, 23), 950: (10, 10, 10),
    },
}

# Maximum RGB distance for snapping to a palette color
_COLOR_SNAP_THRESHOLD: float = 20.0


# ---------------------------------------------------------------------------
# Tailwind v4 scale mappings
# ---------------------------------------------------------------------------

# Font size scale: class name -> px value
_FONT_SIZE_SCALE: Dict[str, float] = {
    "text-xs": 12, "text-sm": 14, "text-base": 16, "text-lg": 18,
    "text-xl": 20, "text-2xl": 24, "text-3xl": 30, "text-4xl": 36,
    "text-5xl": 48, "text-6xl": 60, "text-7xl": 72, "text-8xl": 96,
    "text-9xl": 128,
}

# Font weight scale: numeric -> class name
_FONT_WEIGHT_SCALE: Dict[int, str] = {
    100: "font-thin", 200: "font-extralight", 300: "font-light",
    400: "font-normal", 500: "font-medium", 600: "font-semibold",
    700: "font-bold", 800: "font-extrabold", 900: "font-black",
}

# Border radius scale: class name -> px value (Tailwind v4)
_BORDER_RADIUS_SCALE: Dict[str, float] = {
    "rounded-none": 0, "rounded-xs": 2, "rounded-sm": 4, "rounded": 6,
    "rounded-md": 8, "rounded-lg": 12, "rounded-xl": 16,
    "rounded-2xl": 24, "rounded-3xl": 32, "rounded-full": 9999,
}

# Shadow scale: class name -> approximate blur radius px
_SHADOW_BLUR_SCALE: Dict[str, float] = {
    "shadow-xs": 1, "shadow-sm": 2, "shadow": 4, "shadow-md": 6,
    "shadow-lg": 10, "shadow-xl": 20, "shadow-2xl": 25,
}

# Opacity scale: class name -> value
_OPACITY_SCALE: Dict[str, float] = {
    "opacity-0": 0.0, "opacity-5": 0.05, "opacity-10": 0.10,
    "opacity-15": 0.15, "opacity-20": 0.20, "opacity-25": 0.25,
    "opacity-30": 0.30, "opacity-35": 0.35, "opacity-40": 0.40,
    "opacity-45": 0.45, "opacity-50": 0.50, "opacity-55": 0.55,
    "opacity-60": 0.60, "opacity-65": 0.65, "opacity-70": 0.70,
    "opacity-75": 0.75, "opacity-80": 0.80, "opacity-85": 0.85,
    "opacity-90": 0.90, "opacity-95": 0.95, "opacity-100": 1.0,
}


# ---------------------------------------------------------------------------
# Color mapping
# ---------------------------------------------------------------------------


def _rgb_distance(c1: Tuple[int, int, int], c2: Tuple[int, int, int]) -> float:
    """Euclidean distance between two RGB tuples.

    Args:
        c1: First RGB tuple (0-255).
        c2: Second RGB tuple (0-255).

    Returns:
        Euclidean distance.
    """
    return math.sqrt(
        (c1[0] - c2[0]) ** 2
        + (c1[1] - c2[1]) ** 2
        + (c1[2] - c2[2]) ** 2
    )


def _parse_hex(hex_str: str) -> Optional[Tuple[int, int, int]]:
    """Parse a hex color string to RGB tuple.

    Args:
        hex_str: CSS hex color (e.g., "#ff0000" or "#ff0000aa").

    Returns:
        RGB tuple (0-255), or None if parsing fails.
    """
    hex_str = hex_str.lstrip("#")
    if len(hex_str) < 6:
        return None
    try:
        r = int(hex_str[0:2], 16)
        g = int(hex_str[2:4], 16)
        b = int(hex_str[4:6], 16)
        return (r, g, b)
    except ValueError:
        return None


def _parse_rgba(rgba_str: str) -> Optional[Tuple[int, int, int]]:
    """Parse an rgba() color string to RGB tuple.

    Args:
        rgba_str: CSS rgba color (e.g., "rgba(255, 0, 0, 0.5)").

    Returns:
        RGB tuple (0-255), or None if parsing fails.
    """
    match = re.match(r"rgba?\((\d+),\s*(\d+),\s*(\d+)", rgba_str)
    if match:
        return (int(match.group(1)), int(match.group(2)), int(match.group(3)))
    return None


def _snap_color_named(css_color: str, prefix: str) -> Optional[str]:
    """Return a Tailwind class for CSS named colors, or None if not named."""
    _CSS_NAMED_COLORS = {
        "transparent": f"{prefix}-transparent",
        "currentcolor": f"{prefix}-current",
        "inherit": f"{prefix}-inherit",
        "initial": f"{prefix}-inherit",
        "unset": f"{prefix}-inherit",
        "black": f"{prefix}-black",
        "white": f"{prefix}-white",
    }
    return _CSS_NAMED_COLORS.get(css_color.lower())


def _snap_color_palette(rgb: Tuple[int, int, int], prefix: str) -> str:
    """Find the nearest Tailwind palette color for an RGB tuple."""
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

    if best_dist <= _COLOR_SNAP_THRESHOLD:
        return f"{prefix}-{best_name}-{best_shade}"

    # Use hex arbitrary value
    hex_color = f"#{rgb[0]:02x}{rgb[1]:02x}{rgb[2]:02x}"
    return f"{prefix}-[{hex_color}]"


def snap_color(css_color: str, prefix: str = "bg") -> str:
    """Map a CSS color to the nearest Tailwind palette class.

    If RGB distance to the nearest palette color is within threshold,
    returns the palette class (e.g., ``bg-blue-500``). Otherwise returns
    an arbitrary value class (e.g., ``bg-[#1a2b3c]``).

    Args:
        css_color: CSS color string (hex or rgba).
        prefix: Tailwind utility prefix ("bg", "text", "border").

    Returns:
        Tailwind color class string.
    """
    rgb = _parse_hex(css_color) or _parse_rgba(css_color)
    if rgb is None:
        named = _snap_color_named(css_color, prefix)
        if named:
            return named
        return f"{prefix}-[{css_color}]"

    return _snap_color_palette(rgb, prefix)


# ---------------------------------------------------------------------------
# Spacing mapper
# ---------------------------------------------------------------------------


def _px_to_spacing(px: float) -> str:
    """Convert pixel value to Tailwind spacing unit.

    Tailwind v4 supports arbitrary numeric values (e.g., ``3.5``).
    The base unit is 4px, so ``px / 4`` gives the Tailwind number.

    Args:
        px: Value in pixels.

    Returns:
        Tailwind spacing number string (e.g., "4", "3.5", "[13px]").
    """
    if px <= 0:
        return "0"

    unit = px / 4.0
    # Check for clean values
    if abs(unit - round(unit)) < 1e-9:
        return str(int(round(unit)))
    # Half values
    if abs(unit * 2 - round(unit * 2)) < 1e-9:
        return f"{unit:.1f}"
    # Arbitrary
    return f"[{px:.0f}px]"


# ---------------------------------------------------------------------------
# TailwindMapper
# ---------------------------------------------------------------------------


class TailwindMapper:
    """Maps CSS property dicts to Tailwind v4 utility classes.

    Processes the output of ``StyleBuilder.build()`` and returns a list
    of Tailwind class strings.
    """

    def map_properties(self, props: Dict[str, str]) -> List[str]:
        """Convert a CSS properties dict to Tailwind v4 classes.

        Args:
            props: Dict from ``StyleBuilder.build()``.

        Returns:
            List of Tailwind utility class strings.
        """
        classes: List[str] = []

        for prop, value in props.items():
            mapped = self._map_single(prop, value)
            if mapped:
                classes.extend(mapped)

        return classes

    def _map_single(self, prop: str, value: str) -> List[str]:
        """Map a single CSS property to Tailwind classes.

        Args:
            prop: CSS property name.
            value: CSS property value.

        Returns:
            List of Tailwind classes for this property.
        """
        result = self._map_color_property(prop, value)
        if result is not None:
            return result

        result = self._map_border_property(prop, value)
        if result is not None:
            return result

        result = self._map_dimension_property(prop, value)
        if result is not None:
            return result

        result = self._map_padding_property(prop, value)
        if result is not None:
            return result

        result = self._map_misc_property(prop, value)
        if result is not None:
            return result

        # Internal markers (e.g., _image_ref) are skipped
        if prop.startswith("_"):
            return []

        return []

    def _map_color_property(self, prop: str, value: str) -> Optional[List[str]]:
        """Map color-related CSS properties to Tailwind classes.

        Returns None if the property is not color-related.
        """
        if prop == "background-color":
            return [snap_color(value, "bg")]
        if prop == "color":
            return [snap_color(value, "text")]
        if prop == "background-image":
            return self._map_gradient(value)
        if prop == "opacity":
            return [self._map_opacity(value)]
        return None

    def _map_border_property(self, prop: str, value: str) -> Optional[List[str]]:
        """Map border-related CSS properties to Tailwind classes.

        Returns None if the property is not border-related.
        """
        if prop == "border-color":
            return [snap_color(value, "border")]
        if prop == "border-width":
            return [self._map_border_width(value)]
        if prop == "border-style":
            return [f"border-{value}"]
        if prop == "border-radius":
            return self._map_border_radius(value)
        if prop == "box-shadow":
            return [self._map_shadow(value)]
        if prop == "outline-width":
            px = _parse_px(value)
            if px is not None:
                return [f"outline-{max(1, round(px))}"]
            return []
        if prop == "outline-color":
            return [snap_color(value, "outline")]
        if prop == "outline-style":
            return [f"outline-{value}"]
        if prop == "outline-offset":
            px = _parse_px(value)
            if px is not None:
                return [f"outline-offset-[{value}]"]
            return []
        return None

    def _map_dimension_property(self, prop: str, value: str) -> Optional[List[str]]:
        """Map dimension CSS properties to Tailwind classes.

        Returns None if the property is not a dimension property.
        """
        _dim_map = {
            "width": "w", "height": "h",
            "min-width": "min-w", "max-width": "max-w",
            "min-height": "min-h", "max-height": "max-h",
        }
        prefix = _dim_map.get(prop)
        if prefix is not None:
            return [self._map_dimension(value, prefix)]
        return None

    def _map_padding_property(self, prop: str, value: str) -> Optional[List[str]]:
        """Map padding and gap CSS properties to Tailwind classes.

        Returns None if the property is not padding/gap-related.
        """
        _pad_map = {
            "padding": "p", "padding-x": "px", "padding-y": "py",
            "padding-top": "pt", "padding-right": "pr",
            "padding-bottom": "pb", "padding-left": "pl",
            "gap": "gap",
        }
        tw_prefix = _pad_map.get(prop)
        if tw_prefix is not None:
            px = _parse_px(value)
            return [f"{tw_prefix}-{_px_to_spacing(px)}"] if px is not None else []
        return None

    def _map_misc_property(self, prop: str, value: str) -> Optional[List[str]]:
        """Map miscellaneous CSS properties to Tailwind classes.

        Returns None if the property is not recognized.
        """
        if prop == "filter" and "blur" in value:
            return [self._map_blur(value, "blur")]
        if prop == "backdrop-filter" and "blur" in value:
            return [self._map_blur(value, "backdrop-blur")]
        if prop == "mix-blend-mode":
            return [f"mix-blend-{value}"]
        if prop == "transform" and "rotate" in value:
            return [self._map_rotation(value)]
        if prop == "overflow":
            return [f"overflow-{value}"]
        if prop == "background-size":
            return [f"bg-{value}"]
        if prop == "background-position":
            return [f"bg-{value}"]
        if prop == "background-repeat":
            return [f"bg-{value}"]
        return None

    @staticmethod
    def _resolve_gradient_direction(value: str) -> str:
        """Resolve CSS gradient direction to Tailwind shorthand."""
        _direction_map = {
            "to bottom": "b", "to top": "t", "to right": "r", "to left": "l",
            "to bottom right": "br", "to top right": "tr",
            "to bottom left": "bl", "to top left": "tl",
        }
        for css_dir, d in _direction_map.items():
            if css_dir in value:
                return d
        return "b"  # default

    def _map_gradient(self, value: str) -> List[str]:
        """Map a CSS gradient to Tailwind v4 gradient classes.

        Extracts direction and color stops from CSS gradient syntax,
        mapping them to Tailwind's ``from-``, ``via-``, ``to-`` classes.

        Args:
            value: CSS background-image gradient string.

        Returns:
            List of Tailwind gradient classes.
        """
        if "linear-gradient" in value:
            tw_dir = self._resolve_gradient_direction(value)
            classes = [f"bg-linear-to-{tw_dir}"]
            classes.extend(self._extract_gradient_stops(value))
            return classes

        if "radial-gradient" in value:
            classes = ["bg-radial"]
            classes.extend(self._extract_gradient_stops(value))
            return classes

        if "conic-gradient" in value:
            classes = ["bg-conic"]
            classes.extend(self._extract_gradient_stops(value))
            return classes

        return []

    @staticmethod
    def _extract_gradient_stops(value: str) -> List[str]:
        """Extract color stops from a CSS gradient and map to from/via/to classes.

        Args:
            value: CSS gradient string containing color stops.

        Returns:
            List of Tailwind from-/via-/to- classes.
        """
        # Extract the content inside the gradient function parentheses
        paren_match = re.search(r"gradient\((.+)\)", value)
        if not paren_match:
            return []

        inner = paren_match.group(1)

        # Split on color stops — each is "color position%"
        # Match: hex colors, rgba(), or named colors followed by optional percentage
        stop_pattern = re.findall(
            r"(#[0-9a-fA-F]{3,8}|rgba?\([^)]+\))\s*(\d+%)?",
            inner,
        )
        if not stop_pattern:
            return []

        colors = [match[0] for match in stop_pattern]
        classes: List[str] = []

        if len(colors) >= 1:
            classes.append(snap_color(colors[0], "from"))
        if len(colors) >= 3:
            # Middle stop(s) → via-
            classes.append(snap_color(colors[1], "via"))
        if len(colors) >= 2:
            classes.append(snap_color(colors[-1], "to"))

        return classes

    @staticmethod
    def _map_border_width(value: str) -> str:
        """Map border width to Tailwind class.

        Args:
            value: CSS border-width value (e.g., "1px", "2px").

        Returns:
            Tailwind border width class.
        """
        px = _parse_px(value)
        if px is None or px <= 0:
            return "border-0"
        if px <= 1:
            return "border"
        if px <= 2:
            return "border-2"
        if px <= 4:
            return "border-4"
        if px <= 8:
            return "border-8"
        return f"border-[{px:.0f}px]"

    def _map_border_radius(self, value: str) -> List[str]:
        """Map border-radius to Tailwind classes.

        Args:
            value: CSS border-radius value (uniform or per-corner).

        Returns:
            List of Tailwind rounded classes.
        """
        parts = value.split()
        if len(parts) == 1:
            return [self._snap_radius(parts[0])]

        # Per-corner: TL TR BR BL
        if len(parts) == 4:
            corners = ["tl", "tr", "br", "bl"]
            classes: List[str] = []
            for corner, px_str in zip(corners, parts):
                px = _parse_px(px_str)
                if px is not None and px > 0:
                    snapped = self._snap_radius(px_str)
                    # Replace 'rounded' prefix with corner-specific
                    suffix = snapped.replace("rounded", "")
                    classes.append(f"rounded-{corner}{suffix}")
            return classes

        return [self._snap_radius(parts[0])]

    @staticmethod
    def _snap_radius(value: str) -> str:
        """Snap a border-radius value to the nearest Tailwind scale.

        Args:
            value: CSS px value string (e.g., "8px").

        Returns:
            Tailwind rounded class.
        """
        px = _parse_px(value)
        if px is None or px <= 0:
            return "rounded-none"

        best_class = "rounded"
        best_diff = float("inf")

        for tw_class, scale_px in _BORDER_RADIUS_SCALE.items():
            diff = abs(px - scale_px)
            if diff < best_diff:
                best_diff = diff
                best_class = tw_class

        # If the closest match is more than 2px off, use arbitrary
        if best_diff > 2:
            return f"rounded-[{px:.0f}px]"
        return best_class

    @staticmethod
    def _shadow_has_custom_color(value: str) -> bool:
        """Check if a box-shadow uses a non-standard (non-black) color."""
        color_match = re.search(r"(rgba?\([^)]+\)|#[0-9a-fA-F]{3,8})", value)
        if not color_match:
            return False
        color_str = color_match.group(1)
        # Standard Tailwind shadows use black with varying opacity
        return not re.match(r"rgba\(\s*0,\s*0,\s*0,", color_str)

    @staticmethod
    def _snap_shadow_blur(blur_radius: float) -> str:
        """Snap a blur radius to the nearest named Tailwind shadow class."""
        best_class = "shadow"
        best_diff = float("inf")

        for tw_class, scale_blur in _SHADOW_BLUR_SCALE.items():
            diff = abs(blur_radius - scale_blur)
            if diff < best_diff:
                best_diff = diff
                best_class = tw_class

        return best_class

    @staticmethod
    def _map_shadow(value: str) -> str:
        """Map a box-shadow to a Tailwind shadow class.

        For standard shadows (black/gray, matching Tailwind scale), snaps
        to named classes. For shadows with custom colors or offsets, uses
        arbitrary value syntax to preserve exact design values.

        Args:
            value: CSS box-shadow value (e.g., "2px 4px 6px 0px rgba(0, 0, 0, 0.1)").

        Returns:
            Tailwind shadow class.
        """
        if "inset" in value:
            return "shadow-inner"

        # Parse shadow components: x y blur [spread] color
        blur_match = re.search(
            r"(-?\d+(?:\.\d+)?)px\s+(-?\d+(?:\.\d+)?)px\s+(\d+(?:\.\d+)?)px",
            value,
        )
        if not blur_match:
            return "shadow"

        blur_radius = float(blur_match.group(3))

        # If non-standard color, use arbitrary value to preserve it
        if TailwindMapper._shadow_has_custom_color(value):
            clean = value.strip().replace(", ", ",")
            return f"shadow-[{clean}]"

        # Standard shadow — snap to named class
        return TailwindMapper._snap_shadow_blur(blur_radius)

    @staticmethod
    def _map_opacity(value: str) -> str:
        """Map an opacity value to the nearest Tailwind opacity class.

        Args:
            value: CSS opacity value (0.0-1.0 as string).

        Returns:
            Tailwind opacity class.
        """
        try:
            opacity = float(value)
        except ValueError:
            return "opacity-100"

        best_class = "opacity-100"
        best_diff = float("inf")

        for tw_class, scale_val in _OPACITY_SCALE.items():
            diff = abs(opacity - scale_val)
            if diff < best_diff:
                best_diff = diff
                best_class = tw_class

        return best_class

    @staticmethod
    def _map_dimension(value: str, prefix: str) -> str:
        """Map a width/height value to Tailwind class.

        Args:
            value: CSS dimension value (e.g., "100%", "200px").
            prefix: Tailwind prefix ("w", "h", "min-w", "max-w", etc.).

        Returns:
            Tailwind dimension class.
        """
        if value == "100%":
            return f"{prefix}-full"
        if value == "auto":
            return f"{prefix}-auto"

        px = _parse_px(value)
        if px is not None:
            return f"{prefix}-{_px_to_spacing(px)}"
        return f"{prefix}-[{value}]"

    @staticmethod
    def _map_rotation(value: str) -> str:
        """Map a CSS rotate transform to a Tailwind rotate class.

        Snaps to named Tailwind rotate classes (rotate-45, rotate-90, etc.)
        when the angle is close. Otherwise uses arbitrary value syntax.

        Args:
            value: CSS transform value (e.g., "rotate(-45.0deg)").

        Returns:
            Tailwind rotate class (e.g., "rotate-45", "-rotate-90", "rotate-[12deg]").
        """
        match = re.search(r"rotate\((-?\d+(?:\.\d+)?)deg\)", value)
        if not match:
            return "rotate-0"

        deg = float(match.group(1))
        if abs(deg) < 0.1:
            return "rotate-0"

        # Named Tailwind rotate classes
        named = {0: "rotate-0", 1: "rotate-1", 2: "rotate-2", 3: "rotate-3",
                 6: "rotate-6", 12: "rotate-12", 45: "rotate-45",
                 90: "rotate-90", 180: "rotate-180"}

        abs_deg = abs(deg)
        neg_prefix = "-" if deg < 0 else ""

        # Snap to named class if within 0.5 degrees
        for named_deg, tw_class in named.items():
            if abs(abs_deg - named_deg) < 0.5:
                return f"{neg_prefix}{tw_class}"

        # Arbitrary value
        rounded = round(deg)
        return f"rotate-[{rounded}deg]"

    @staticmethod
    def _map_blur(value: str, prefix: str) -> str:
        """Map a blur filter value to Tailwind class.

        Args:
            value: CSS blur value (e.g., "blur(4px)").
            prefix: "blur" or "backdrop-blur".

        Returns:
            Tailwind blur class.
        """
        match = re.search(r"blur\((\d+(?:\.\d+)?)px\)", value)
        if not match:
            return prefix

        radius = float(match.group(1))
        blur_scale = {
            "xs": 2, "sm": 4, "": 8, "md": 12, "lg": 16,
            "xl": 24, "2xl": 40, "3xl": 64,
        }

        best_suffix = ""
        best_diff = float("inf")

        for suffix, scale_px in blur_scale.items():
            diff = abs(radius - scale_px)
            if diff < best_diff:
                best_diff = diff
                best_suffix = suffix

        if best_suffix:
            return f"{prefix}-{best_suffix}"
        return prefix


# ---------------------------------------------------------------------------
# Typography helpers
# ---------------------------------------------------------------------------


def map_font_size(px: float) -> str:
    """Map a font size in pixels to the nearest Tailwind text class.

    Args:
        px: Font size in pixels.

    Returns:
        Tailwind text size class (e.g., "text-base" or "text-[17px]").
    """
    best_class = "text-base"
    best_diff = float("inf")

    for tw_class, scale_px in _FONT_SIZE_SCALE.items():
        diff = abs(px - scale_px)
        if diff < best_diff:
            best_diff = diff
            best_class = tw_class

    # If closest match is more than 1px off, use arbitrary
    if best_diff > 1:
        return f"text-[{px:.0f}px]"
    return best_class


def map_font_weight(weight: float) -> str:
    """Map a numeric font weight to Tailwind class.

    Args:
        weight: Numeric font weight (100-900).

    Returns:
        Tailwind font weight class (e.g., "font-bold").
    """
    rounded = round(weight / 100) * 100
    rounded = max(100, min(900, rounded))
    return _FONT_WEIGHT_SCALE.get(rounded, f"font-[{int(weight)}]")


def map_letter_spacing(px: float) -> str:
    """Map letter spacing in pixels to Tailwind tracking class.

    Args:
        px: Letter spacing in pixels.

    Returns:
        Tailwind tracking class.
    """
    # Tailwind tracking scale (approximate em values at 16px base)
    if px <= -0.8:
        return "tracking-tighter"
    if px <= -0.4:
        return "tracking-tight"
    if abs(px) < 0.1:
        return "tracking-normal"
    if px <= 0.4:
        return "tracking-wide"
    if px <= 0.8:
        return "tracking-wider"
    return "tracking-widest"


def map_line_height(px: float, font_size: float) -> str:
    """Map line height to Tailwind leading class.

    Args:
        px: Line height in pixels.
        font_size: Font size in pixels (for ratio calculation).

    Returns:
        Tailwind leading class.
    """
    if font_size <= 0:
        return "leading-normal"

    ratio = px / font_size

    if ratio <= 1.0:
        return "leading-none"
    if ratio <= 1.15:
        return "leading-tight"
    if ratio <= 1.375:
        return "leading-snug"
    if ratio <= 1.5:
        return "leading-normal"
    if ratio <= 1.625:
        return "leading-relaxed"
    return "leading-loose"


def map_text_align(horizontal: Optional[str]) -> Optional[str]:
    """Map text alignment to Tailwind class.

    Args:
        horizontal: Figma text alignment (LEFT, CENTER, RIGHT, JUSTIFIED).

    Returns:
        Tailwind text alignment class, or None for LEFT (default).
    """
    align_map = {
        "CENTER": "text-center",
        "RIGHT": "text-right",
        "JUSTIFIED": "text-justify",
    }
    return align_map.get(horizontal or "")


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _parse_px(value: str) -> Optional[float]:
    """Parse a CSS pixel value to float.

    Args:
        value: CSS value string (e.g., "16px", "0").

    Returns:
        Numeric value in pixels, or None if parsing fails.
    """
    value = value.strip()
    if value.endswith("px"):
        value = value[:-2]
    try:
        return float(value)
    except ValueError:
        return None
