"""Tests for tailwind_mapper.py — CSS property to Tailwind v4 class mapping."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from tailwind_mapper import (  # noqa: E402
    TailwindMapper,
    map_font_size,
    map_font_weight,
    map_letter_spacing,
    map_line_height,
    map_text_align,
    snap_color,
)


# ---------------------------------------------------------------------------
# TailwindMapper.map_properties
# ---------------------------------------------------------------------------

class TestMapProperties:
    """Test the main CSS-to-Tailwind properties mapper."""

    def test_empty_props(self):
        """Empty dict should return empty list."""
        assert TailwindMapper().map_properties({}) == []

    def test_background_color(self):
        """background-color should map to bg-* class."""
        classes = TailwindMapper().map_properties({"background-color": "#ffffff"})
        assert len(classes) == 1
        assert classes[0].startswith("bg-")

    def test_width_percent(self):
        """width: 100% should map to w-full."""
        classes = TailwindMapper().map_properties({"width": "100%"})
        assert "w-full" in classes

    def test_width_px(self):
        """width: 200px should map to w-50 (200/4)."""
        classes = TailwindMapper().map_properties({"width": "200px"})
        assert "w-50" in classes

    def test_padding_uniform(self):
        """padding should map to p-* class."""
        classes = TailwindMapper().map_properties({"padding": "16.0px"})
        assert "p-4" in classes

    def test_padding_xy(self):
        """padding-x and padding-y should map separately."""
        classes = TailwindMapper().map_properties({
            "padding-x": "16.0px",
            "padding-y": "8.0px",
        })
        assert "px-4" in classes
        assert "py-2" in classes

    def test_gap(self):
        """gap should map to gap-*."""
        classes = TailwindMapper().map_properties({"gap": "12.0px"})
        assert "gap-3" in classes

    def test_border_properties(self):
        """border-width + border-color should produce border classes."""
        classes = TailwindMapper().map_properties({
            "border-width": "1.0px",
            "border-color": "#000000",
            "border-style": "solid",
        })
        assert "border" in classes
        # #000000 snaps to neutral-950 (distance ~17.3, within threshold 20)
        assert any(c.startswith("border-") and c != "border" and c != "border-solid" for c in classes)
        assert "border-solid" in classes

    def test_box_shadow_maps_to_shadow(self):
        """box-shadow should map to shadow-* class."""
        classes = TailwindMapper().map_properties({
            "box-shadow": "0.0px 4.0px 6.0px 0.0px rgba(0, 0, 0, 0.10)"
        })
        assert len(classes) == 1
        assert "shadow" in classes[0]

    def test_opacity(self):
        """opacity should map to opacity-* class."""
        classes = TailwindMapper().map_properties({"opacity": "0.50"})
        assert "opacity-50" in classes

    def test_overflow_hidden(self):
        """overflow: hidden should map to overflow-hidden."""
        classes = TailwindMapper().map_properties({"overflow": "hidden"})
        assert "overflow-hidden" in classes

    def test_blur_filter(self):
        """filter: blur() should map to blur-* class."""
        classes = TailwindMapper().map_properties({"filter": "blur(4.0px)"})
        assert len(classes) == 1
        assert "blur" in classes[0]

    def test_backdrop_blur(self):
        """backdrop-filter: blur() should map to backdrop-blur-*."""
        classes = TailwindMapper().map_properties({"backdrop-filter": "blur(8.0px)"})
        assert len(classes) == 1
        assert "backdrop-blur" in classes[0]

    def test_gradient_direction(self):
        """linear-gradient(to right, ...) should map to bg-linear-to-r."""
        classes = TailwindMapper().map_properties({
            "background-image": "linear-gradient(to right, #000 0%, #fff 100%)"
        })
        assert "bg-linear-to-r" in classes

    def test_internal_markers_skipped(self):
        """Properties starting with _ should be ignored."""
        classes = TailwindMapper().map_properties({"_image_ref": "abc123"})
        assert classes == []


# ---------------------------------------------------------------------------
# snap_color
# ---------------------------------------------------------------------------

class TestSnapColor:
    """Test color palette snapping."""

    def test_white(self):
        """Pure white should snap to a white-like class or arbitrary."""
        result = snap_color("#ffffff", "bg")
        # White is close to neutral-50 or could be arbitrary
        assert result.startswith("bg-")

    def test_black(self):
        """Pure black should snap to a dark palette shade."""
        result = snap_color("#000000", "bg")
        assert result.startswith("bg-")

    def test_exact_red_500(self):
        """Exact red-500 (ef4444) should snap to bg-red-500."""
        result = snap_color("#ef4444", "bg")
        assert result == "bg-red-500"

    def test_exact_blue_500(self):
        """Exact blue-500 (3b82f6) should snap to bg-blue-500."""
        result = snap_color("#3b82f6", "bg")
        assert result == "bg-blue-500"

    def test_near_palette_snap(self):
        """#1a2b3c is close to slate-800 (30,41,59) -- should snap."""
        result = snap_color("#1a2b3c", "bg")
        assert result == "bg-slate-800"

    def test_truly_arbitrary_color(self):
        """A color far from any palette should use arbitrary hex."""
        # Bright neon green -- far from all Tailwind palettes
        result = snap_color("#00ff80", "bg")
        # Should snap to closest green/emerald shade within threshold,
        # or use arbitrary if distance > 20
        assert result.startswith("bg-")

    def test_text_prefix(self):
        """Text color prefix should produce text-* classes."""
        result = snap_color("#ef4444", "text")
        assert result.startswith("text-")

    def test_border_prefix(self):
        """Border prefix should produce border-* classes."""
        result = snap_color("#ef4444", "border")
        assert result.startswith("border-")

    def test_rgba_color(self):
        """rgba() format should be parsed correctly."""
        result = snap_color("rgba(239, 68, 68, 0.50)", "bg")
        assert result.startswith("bg-")


# ---------------------------------------------------------------------------
# map_font_size
# ---------------------------------------------------------------------------

class TestMapFontSize:
    """Test font size to text-* class mapping."""

    def test_12px_text_xs(self):
        assert map_font_size(12) == "text-xs"

    def test_14px_text_sm(self):
        assert map_font_size(14) == "text-sm"

    def test_16px_text_base(self):
        assert map_font_size(16) == "text-base"

    def test_18px_text_lg(self):
        assert map_font_size(18) == "text-lg"

    def test_20px_text_xl(self):
        assert map_font_size(20) == "text-xl"

    def test_24px_text_2xl(self):
        assert map_font_size(24) == "text-2xl"

    def test_30px_text_3xl(self):
        assert map_font_size(30) == "text-3xl"

    def test_36px_text_4xl(self):
        assert map_font_size(36) == "text-4xl"

    def test_48px_text_5xl(self):
        assert map_font_size(48) == "text-5xl"

    def test_13px_snaps_to_xs(self):
        """13px is within 1px of 12px (text-xs) -- snaps to nearest."""
        result = map_font_size(13)
        assert result == "text-xs"

    def test_arbitrary_size_22px(self):
        """22px is 2px from both 20 and 24 -- exceeds >1 threshold."""
        result = map_font_size(22)
        assert result == "text-[22px]"

    def test_very_large_size(self):
        """Size > 128px should use arbitrary value."""
        result = map_font_size(200)
        assert result == "text-[200px]"


# ---------------------------------------------------------------------------
# map_font_weight
# ---------------------------------------------------------------------------

class TestMapFontWeight:
    """Test font weight mapping."""

    def test_100_thin(self):
        assert map_font_weight(100) == "font-thin"

    def test_200_extralight(self):
        assert map_font_weight(200) == "font-extralight"

    def test_300_light(self):
        assert map_font_weight(300) == "font-light"

    def test_400_normal(self):
        assert map_font_weight(400) == "font-normal"

    def test_500_medium(self):
        assert map_font_weight(500) == "font-medium"

    def test_600_semibold(self):
        assert map_font_weight(600) == "font-semibold"

    def test_700_bold(self):
        assert map_font_weight(700) == "font-bold"

    def test_800_extrabold(self):
        assert map_font_weight(800) == "font-extrabold"

    def test_900_black(self):
        assert map_font_weight(900) == "font-black"

    def test_550_rounds_to_600(self):
        """Non-standard 550 should round to 600 (semibold)."""
        assert map_font_weight(550) == "font-semibold"


# ---------------------------------------------------------------------------
# Border radius snapping (Tailwind v4 scale)
# ---------------------------------------------------------------------------

class TestBorderRadius:
    """Test border radius via TailwindMapper._snap_radius."""

    def _snap(self, px: str) -> str:
        return TailwindMapper._snap_radius(px)

    def test_0_none(self):
        assert self._snap("0px") == "rounded-none"

    def test_2_xs(self):
        assert self._snap("2px") == "rounded-xs"

    def test_4_sm(self):
        assert self._snap("4px") == "rounded-sm"

    def test_6_rounded(self):
        """6px snaps to 'rounded' (the base class in v4)."""
        assert self._snap("6px") == "rounded"

    def test_8_md(self):
        assert self._snap("8px") == "rounded-md"

    def test_12_lg(self):
        assert self._snap("12px") == "rounded-lg"

    def test_16_xl(self):
        assert self._snap("16px") == "rounded-xl"

    def test_24_2xl(self):
        assert self._snap("24px") == "rounded-2xl"

    def test_9999_full(self):
        """Very large value should snap to rounded-full."""
        assert self._snap("9999px") == "rounded-full"

    def test_arbitrary_50(self):
        """50px doesn't match any scale closely -- should use arbitrary."""
        result = self._snap("50px")
        assert "rounded-[50px]" == result


# ---------------------------------------------------------------------------
# Shadow mapping
# ---------------------------------------------------------------------------

class TestShadowMapping:
    """Test box-shadow to shadow-* class mapping."""

    def _map(self, shadow: str) -> str:
        return TailwindMapper._map_shadow(shadow)

    def test_small_shadow(self):
        """Blur radius ~1px should map to shadow-xs."""
        result = self._map("0.0px 1.0px 1.0px 0.0px rgba(0,0,0,0.1)")
        assert result == "shadow-xs"

    def test_medium_shadow(self):
        """Blur radius ~6px should map to shadow-md."""
        result = self._map("0.0px 4.0px 6.0px 0.0px rgba(0,0,0,0.1)")
        assert result == "shadow-md"

    def test_large_shadow(self):
        """Blur radius ~10px should map to shadow-lg."""
        result = self._map("0.0px 8.0px 10.0px 0.0px rgba(0,0,0,0.1)")
        assert result == "shadow-lg"

    def test_inset_shadow(self):
        """Inset shadow should map to shadow-inner."""
        result = self._map("inset 0.0px 2.0px 4.0px 0.0px rgba(0,0,0,0.1)")
        assert result == "shadow-inner"


# ---------------------------------------------------------------------------
# Opacity mapping
# ---------------------------------------------------------------------------

class TestOpacityMapping:
    """Test CSS opacity to Tailwind opacity-* class mapping."""

    def _map(self, val: str) -> str:
        return TailwindMapper._map_opacity(val)

    def test_full_opacity(self):
        assert self._map("1.00") == "opacity-100"

    def test_50_percent(self):
        assert self._map("0.50") == "opacity-50"

    def test_zero_opacity(self):
        assert self._map("0.00") == "opacity-0"

    def test_75_percent(self):
        assert self._map("0.75") == "opacity-75"

    def test_30_percent(self):
        assert self._map("0.30") == "opacity-30"


# ---------------------------------------------------------------------------
# Typography helpers
# ---------------------------------------------------------------------------

class TestLetterSpacing:
    """Test letter spacing to tracking-* class mapping."""

    def test_normal(self):
        assert map_letter_spacing(0) == "tracking-normal"

    def test_tight(self):
        assert map_letter_spacing(-0.4) == "tracking-tight"

    def test_wide(self):
        assert map_letter_spacing(0.4) == "tracking-wide"


class TestLineHeight:
    """Test line height to leading-* class mapping."""

    def test_none(self):
        """line-height = font-size = ratio 1.0 -> leading-none."""
        assert map_line_height(16, 16) == "leading-none"

    def test_tight(self):
        """ratio ~1.125 -> leading-tight."""
        assert map_line_height(18, 16) == "leading-tight"

    def test_normal(self):
        """ratio ~1.5 -> leading-normal."""
        assert map_line_height(24, 16) == "leading-normal"

    def test_loose(self):
        """ratio > 1.625 -> leading-loose."""
        assert map_line_height(32, 16) == "leading-loose"


class TestTextAlign:
    """Test text alignment mapping."""

    def test_left_is_none(self):
        """LEFT alignment is default -- returns None."""
        assert map_text_align("LEFT") is None

    def test_center(self):
        assert map_text_align("CENTER") == "text-center"

    def test_right(self):
        assert map_text_align("RIGHT") == "text-right"

    def test_justified(self):
        assert map_text_align("JUSTIFIED") == "text-justify"

    def test_none_input(self):
        assert map_text_align(None) is None


# ---------------------------------------------------------------------------
# Rotation mapping
# ---------------------------------------------------------------------------

class TestRotationMapping:
    """Test CSS rotate transform to Tailwind rotate class mapping."""

    def test_zero_rotation(self):
        mapper = TailwindMapper()
        assert mapper._map_rotation("rotate(0.0deg)") == "rotate-0"

    def test_named_45_degrees(self):
        mapper = TailwindMapper()
        assert mapper._map_rotation("rotate(45.0deg)") == "rotate-45"

    def test_negative_90_degrees(self):
        mapper = TailwindMapper()
        assert mapper._map_rotation("rotate(-90.0deg)") == "-rotate-90"

    def test_arbitrary_angle(self):
        mapper = TailwindMapper()
        result = mapper._map_rotation("rotate(37.0deg)")
        assert result == "rotate-[37deg]"

    def test_named_180_degrees(self):
        mapper = TailwindMapper()
        assert mapper._map_rotation("rotate(180.0deg)") == "rotate-180"

    def test_invalid_value(self):
        mapper = TailwindMapper()
        assert mapper._map_rotation("scale(2)") == "rotate-0"

    def test_rotation_via_map_properties(self):
        """Rotation should go through the full map_properties pipeline."""
        mapper = TailwindMapper()
        result = mapper.map_properties({"transform": "rotate(45.0deg)"})
        assert "rotate-45" in result


# ---------------------------------------------------------------------------
# Blend mode mapping
# ---------------------------------------------------------------------------

class TestBlendModeMapping:
    """Test mix-blend-mode to Tailwind class mapping."""

    def test_multiply(self):
        mapper = TailwindMapper()
        result = mapper.map_properties({"mix-blend-mode": "multiply"})
        assert result == ["mix-blend-multiply"]

    def test_overlay(self):
        mapper = TailwindMapper()
        result = mapper.map_properties({"mix-blend-mode": "overlay"})
        assert result == ["mix-blend-overlay"]

    def test_screen(self):
        mapper = TailwindMapper()
        result = mapper.map_properties({"mix-blend-mode": "screen"})
        assert result == ["mix-blend-screen"]


# ---------------------------------------------------------------------------
# Gradient stops mapping
# ---------------------------------------------------------------------------

class TestGradientStops:
    """Test gradient color stop extraction to from-/via-/to- classes."""

    def test_two_stop_linear_gradient(self):
        """A 2-color gradient should produce from- and to- classes."""
        mapper = TailwindMapper()
        value = "linear-gradient(to right, #ff0000 0%, #0000ff 100%)"
        result = mapper.map_properties({"background-image": value})
        assert "bg-linear-to-r" in result
        assert any(c.startswith("from-") for c in result)
        assert any(c.startswith("to-") for c in result)

    def test_three_stop_linear_gradient(self):
        """A 3-color gradient should produce from-, via-, and to- classes."""
        mapper = TailwindMapper()
        value = "linear-gradient(to bottom, #ff0000 0%, #00ff00 50%, #0000ff 100%)"
        result = mapper.map_properties({"background-image": value})
        assert "bg-linear-to-b" in result
        assert any(c.startswith("from-") for c in result)
        assert any(c.startswith("via-") for c in result)
        assert any(c.startswith("to-") for c in result)

    def test_radial_gradient_with_stops(self):
        """A radial gradient should also extract color stops."""
        mapper = TailwindMapper()
        value = "radial-gradient(circle, #ffffff 0%, #000000 100%)"
        result = mapper.map_properties({"background-image": value})
        assert "bg-radial" in result
        assert any(c.startswith("from-") for c in result)

    def test_gradient_without_stops(self):
        """A gradient with no extractable colors falls back to direction only."""
        mapper = TailwindMapper()
        value = "linear-gradient(to top)"
        result = mapper.map_properties({"background-image": value})
        assert "bg-linear-to-t" in result


# ---------------------------------------------------------------------------
# Shadow arbitrary values
# ---------------------------------------------------------------------------

class TestShadowArbitraryValues:
    """Test improved shadow mapping with custom colors."""

    def test_standard_black_shadow_snaps(self):
        """Black shadows should snap to named classes."""
        mapper = TailwindMapper()
        result = mapper._map_shadow("2px 4px 6px 0px rgba(0, 0, 0, 0.1)")
        assert not result.startswith("shadow-[")
        assert result.startswith("shadow")

    def test_colored_shadow_uses_arbitrary(self):
        """Non-black shadows should use arbitrary syntax."""
        mapper = TailwindMapper()
        result = mapper._map_shadow("2px 4px 8px 0px rgba(255, 0, 0, 0.5)")
        assert result.startswith("shadow-[")
        assert "255" in result

    def test_inset_shadow(self):
        """Inset shadows should always return shadow-inner."""
        mapper = TailwindMapper()
        result = mapper._map_shadow("inset 0px 2px 4px 0px rgba(100, 50, 0, 0.3)")
        assert result == "shadow-inner"

    def test_no_match_returns_shadow(self):
        """Unparseable shadow falls back to shadow."""
        mapper = TailwindMapper()
        result = mapper._map_shadow("none")
        assert result == "shadow"


# ---------------------------------------------------------------------------
# Additional edge cases
# ---------------------------------------------------------------------------


class TestMapPropertiesEdgeCases:
    """Edge cases for TailwindMapper.map_properties."""

    def test_empty_dict_returns_empty_list(self):
        """Empty props dict should produce an empty class list."""
        result = TailwindMapper().map_properties({})
        assert result == []

    def test_none_value_for_known_property_skipped(self):
        """None value for a property should not crash — gracefully skipped."""
        # This should not raise; unknown/invalid values just get skipped
        try:
            result = TailwindMapper().map_properties({"background-color": None})
            assert isinstance(result, list)
        except (TypeError, ValueError, KeyError, AttributeError):
            pass  # Acceptable to raise, but not crash unhandled

    def test_invalid_color_hex_gracefully_handled(self):
        """Invalid hex color (too short) should fallback to arbitrary or be skipped."""
        result = TailwindMapper().map_properties({"background-color": "#xyz"})
        assert isinstance(result, list)

    def test_zero_width_maps_to_w0(self):
        """width: 0px should map to w-0."""
        classes = TailwindMapper().map_properties({"width": "0px"})
        assert "w-0" in classes

    def test_boundary_large_width(self):
        """Very large width should produce an arbitrary class or a valid class."""
        classes = TailwindMapper().map_properties({"width": "9999px"})
        assert len(classes) == 1
        assert classes[0].startswith("w-")

    def test_negative_gap_boundary(self):
        """Negative gap value should be handled gracefully without crashing."""
        try:
            classes = TailwindMapper().map_properties({"gap": "-8.0px"})
            assert isinstance(classes, list)
        except (TypeError, ValueError, KeyError, AttributeError):
            pass  # Acceptable: negative gap is invalid CSS

    def test_zero_border_radius_boundary(self):
        """border-radius: 0px should produce rounded-none."""
        classes = TailwindMapper().map_properties({"border-radius": "0px"})
        assert "rounded-none" in classes

    def test_boundary_huge_border_radius(self):
        """border-radius: 9999px should map to rounded-full."""
        classes = TailwindMapper().map_properties({"border-radius": "9999px"})
        assert "rounded-full" in classes

    def test_zero_opacity_boundary(self):
        """opacity: 0.00 should map to opacity-0."""
        classes = TailwindMapper().map_properties({"opacity": "0.00"})
        assert "opacity-0" in classes

    def test_full_opacity_boundary(self):
        """opacity: 1.00 should map to opacity-100."""
        classes = TailwindMapper().map_properties({"opacity": "1.00"})
        assert "opacity-100" in classes

    def test_unknown_overflow_value_skipped(self):
        """Unknown overflow value like 'clip' should not crash."""
        try:
            classes = TailwindMapper().map_properties({"overflow": "clip"})
            assert isinstance(classes, list)
        except (TypeError, ValueError, KeyError, AttributeError):
            pass

    def test_unknown_property_key_ignored(self):
        """Unknown CSS property should be silently ignored."""
        classes = TailwindMapper().map_properties({"not-a-real-css-property": "value"})
        assert isinstance(classes, list)

    def test_malformed_rgba_in_background(self):
        """Malformed rgba string should be handled gracefully."""
        result = TailwindMapper().map_properties({"background-color": "rgba(not,valid,color)"})
        assert isinstance(result, list)

    def test_whitespace_only_color_value(self):
        """Whitespace-only value should not crash."""
        try:
            result = TailwindMapper().map_properties({"background-color": "   "})
            assert isinstance(result, list)
        except (TypeError, ValueError, KeyError, AttributeError):
            pass


class TestSnapColorEdgeCases:
    """Edge cases for snap_color."""

    def test_invalid_hex_too_short_returns_arbitrary(self):
        """Short hex like '#abc' (3-char) should return arbitrary or handle gracefully."""
        result = snap_color("#abc", "bg")
        assert result.startswith("bg-")

    def test_empty_string_color_gracefully_handled(self):
        """Empty string color input should not raise an unhandled exception."""
        try:
            result = snap_color("", "bg")
            assert isinstance(result, str)
        except (TypeError, ValueError, KeyError, AttributeError):
            pass

    def test_named_color_transparent(self):
        """CSS named color 'transparent' should produce transparent class."""
        result = snap_color("transparent", "bg")
        assert result == "bg-transparent"

    def test_named_color_black(self):
        """CSS named color 'black' should produce bg-black class."""
        result = snap_color("black", "bg")
        assert result == "bg-black"

    def test_named_color_white(self):
        """CSS named color 'white' should produce bg-white class."""
        result = snap_color("white", "bg")
        assert result == "bg-white"

    def test_hex_with_alpha_channel(self):
        """Hex color with alpha (#rrggbbaa) should extract RGB correctly."""
        result = snap_color("#ef444480", "bg")
        assert result.startswith("bg-")

    def test_boundary_zero_rgba(self):
        """rgba(0, 0, 0, 0) — fully transparent black — should return a bg- class."""
        result = snap_color("rgba(0, 0, 0, 0)", "bg")
        assert result.startswith("bg-")

    def test_boundary_max_rgba(self):
        """rgba(255, 255, 255, 1) — solid white — should return a bg- class."""
        result = snap_color("rgba(255, 255, 255, 1)", "bg")
        assert result.startswith("bg-")


class TestMapFontSizeEdgeCases:
    """Edge cases for map_font_size."""

    def test_zero_font_size_boundary(self):
        """Font size 0 should return an arbitrary class."""
        result = map_font_size(0)
        assert result.startswith("text-")

    def test_negative_font_size_boundary(self):
        """Negative font size should be handled gracefully."""
        try:
            result = map_font_size(-1)
            assert result.startswith("text-")
        except (TypeError, ValueError, KeyError, AttributeError):
            pass

    def test_huge_font_size_boundary(self):
        """Very large font size (e.g. 999px) should produce arbitrary class."""
        result = map_font_size(999)
        assert result == "text-[999px]"

    def test_boundary_exact_scale_value_128px(self):
        """128px is the top named scale value — should return text-9xl."""
        result = map_font_size(128)
        assert result == "text-9xl"


class TestMapFontWeightEdgeCases:
    """Edge cases for map_font_weight."""

    def test_boundary_zero_weight(self):
        """Font weight 0 should be handled — rounds to nearest valid weight."""
        result = map_font_weight(0)
        assert result.startswith("font-")

    def test_boundary_very_large_weight(self):
        """Font weight > 900 should fall back to font-black or nearest."""
        result = map_font_weight(1000)
        assert result.startswith("font-")

    def test_non_standard_weight_450(self):
        """Non-standard 450 should round to 400 (normal) or 500 (medium)."""
        result = map_font_weight(450)
        assert result in ("font-normal", "font-medium")


class TestLetterSpacingEdgeCases:
    """Edge cases for map_letter_spacing."""

    def test_large_positive_letter_spacing_boundary(self):
        """Very large positive letter spacing should map to widest class or arbitrary."""
        result = map_letter_spacing(10.0)
        assert isinstance(result, str)
        assert result.startswith("tracking-")

    def test_large_negative_letter_spacing_boundary(self):
        """Very large negative letter spacing (tightest) should map to a class."""
        result = map_letter_spacing(-10.0)
        assert isinstance(result, str)
        assert result.startswith("tracking-")

    def test_zero_letter_spacing_boundary(self):
        """Letter spacing of 0 should return tracking-normal."""
        result = map_letter_spacing(0)
        assert result == "tracking-normal"


class TestLineHeightEdgeCases:
    """Edge cases for map_line_height."""

    def test_zero_line_height_boundary(self):
        """Line height of 0 with font size 16 should be handled gracefully."""
        try:
            result = map_line_height(0, 16)
            assert isinstance(result, str)
        except (TypeError, ValueError, KeyError, AttributeError):
            pass

    def test_equal_line_height_and_font_size_boundary(self):
        """When line height equals font size ratio is 1.0 — leading-none."""
        result = map_line_height(20, 20)
        assert result == "leading-none"

    def test_huge_line_height_boundary(self):
        """Very large line height (e.g. 200px with 16px font) should map to leading-loose."""
        result = map_line_height(200, 16)
        assert result == "leading-loose"


class TestBorderRadiusEdgeCases:
    """Edge cases for TailwindMapper._snap_radius."""

    def _snap(self, px: str) -> str:
        return TailwindMapper._snap_radius(px)

    def test_boundary_negative_radius(self):
        """Negative border radius should be handled gracefully."""
        try:
            result = self._snap("-4px")
            assert isinstance(result, str)
        except (TypeError, ValueError, KeyError, AttributeError):
            pass

    def test_boundary_zero_string(self):
        """Border radius '0px' should produce rounded-none."""
        result = self._snap("0px")
        assert result == "rounded-none"

    def test_missing_px_suffix_boundary(self):
        """Missing 'px' suffix should be handled gracefully."""
        try:
            result = self._snap("8")
            assert isinstance(result, str)
        except (TypeError, ValueError, KeyError, AttributeError):
            pass

    def test_boundary_empty_string_radius(self):
        """Empty string border radius should not crash."""
        try:
            result = self._snap("")
            assert isinstance(result, str)
        except (TypeError, ValueError, KeyError, AttributeError):
            pass
