"""Tests for semantic_classifier.py — 3-tier UI component classification."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from figma_types import (  # noqa: E402
    ComponentPropertyDefinition,
    FigmaPropertyType,
    LayoutMode,
    NodeType,
    Paint,
    PaintType,
)
from node_parser import FigmaIRNode  # noqa: E402
from semantic_classifier import (  # noqa: E402
    CONFIDENCE_THRESHOLD,
    annotate,
    classify,
)


# ---------------------------------------------------------------------------
# Helper
# ---------------------------------------------------------------------------

def _make_node(**overrides) -> FigmaIRNode:
    """Create an IR node with sensible defaults, overriding as needed."""
    defaults = dict(node_id="1:1", name="TestNode", node_type=NodeType.FRAME)
    defaults.update(overrides)
    return FigmaIRNode(**defaults)


def _make_text_child(text: str, **overrides) -> FigmaIRNode:
    """Create a TEXT child node with content."""
    defaults = dict(
        node_id="t:1",
        name="Text",
        node_type=NodeType.TEXT,
        text_content=text,
    )
    defaults.update(overrides)
    return FigmaIRNode(**defaults)


def _make_vector_child(**overrides) -> FigmaIRNode:
    """Create a VECTOR child node (icon-like)."""
    defaults = dict(node_id="v:1", name="Icon", node_type=NodeType.VECTOR)
    defaults.update(overrides)
    return FigmaIRNode(**defaults)


def _make_frame_child(width: float = 400.0, **overrides) -> FigmaIRNode:
    """Create a frame-like child node (row-like)."""
    defaults = dict(
        node_id="f:1",
        name="Row",
        node_type=NodeType.FRAME,
        is_frame_like=True,
        width=width,
    )
    defaults.update(overrides)
    return FigmaIRNode(**defaults)


def _make_prop_def(
    prop_type: FigmaPropertyType = FigmaPropertyType.VARIANT,
    default_value: str = "",
) -> ComponentPropertyDefinition:
    """Create a component property definition."""
    return ComponentPropertyDefinition(type=prop_type, defaultValue=default_value)


# ---------------------------------------------------------------------------
# Tier 1 — Name-based classification
# ---------------------------------------------------------------------------


class TestNameBasedClassification:
    """Tier 1: regex pattern matching on node.name."""

    @pytest.mark.parametrize(
        "name, expected_role",
        [
            ("Pagination", "pagination"),
            ("page-nav", "pagination"),
            ("UserAvatar", "avatar"),
            ("profile_pic", "avatar"),
            ("MainToolbar", "toolbar"),
            ("action bar", "toolbar"),
            ("DataTable", "data-table"),
            ("grid_table", "data-table"),
            ("Breadcrumb", "breadcrumb"),
            ("Tab", "tabs"),
            ("tab-group", "tabs"),
            ("SearchBar", "search"),
            ("search_input", "search"),
            ("StatusBadge", "badge"),
            ("chip", "badge"),
            ("ContentCard", "card"),
            ("Modal", "modal"),
            ("dialog", "modal"),
            ("Sidebar", "sidebar"),
            ("side-nav", "sidebar"),
            ("Stepper", "stepper"),
            ("step_indicator", "stepper"),
            ("EmptyState", "empty-state"),
            ("no-data", "empty-state"),
            ("no_results", "empty-state"),
        ],
    )
    def test_name_patterns(self, name: str, expected_role: str):
        node = _make_node(name=name)
        role, confidence = classify(node)
        assert role == expected_role
        assert confidence == 0.90

    def test_case_insensitive(self):
        node = _make_node(name="PAGINATION")
        role, _ = classify(node)
        assert role == "pagination"

    def test_name_with_prefix(self):
        """Name containing the keyword anywhere should match."""
        node = _make_node(name="Main / Sidebar / Nav")
        role, _ = classify(node)
        assert role == "sidebar"

    def test_unknown_name_returns_none(self):
        node = _make_node(name="RandomContainer")
        role, confidence = classify(node)
        assert role is None
        assert confidence == 0.0

    def test_empty_name(self):
        node = _make_node(name="")
        role, confidence = classify(node)
        assert role is None
        assert confidence == 0.0


# ---------------------------------------------------------------------------
# Tier 2 — Structural heuristic classification
# ---------------------------------------------------------------------------


class TestStructuralClassification:
    """Tier 2: children composition and layout analysis."""

    def test_pagination_detection_by_structure(self):
        """Horizontal frame + icon + numeric text = pagination."""
        children = [
            _make_vector_child(node_id="v:1"),
            _make_text_child("1", node_id="t:1"),
            _make_text_child("2", node_id="t:2"),
            _make_vector_child(node_id="v:2"),
        ]
        node = _make_node(
            name="NavControls",  # No name match
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            children=children,
        )
        role, confidence = classify(node)
        assert role == "pagination"
        assert confidence == 0.78

    def test_pagination_requires_horizontal(self):
        """Vertical layout should not trigger pagination heuristic."""
        children = [
            _make_vector_child(node_id="v:1"),
            _make_text_child("1", node_id="t:1"),
            _make_text_child("2", node_id="t:2"),
            _make_vector_child(node_id="v:2"),
        ]
        node = _make_node(
            name="VertList",
            has_auto_layout=True,
            layout_mode=LayoutMode.VERTICAL,
            children=children,
        )
        role, confidence = classify(node)
        assert role is None
        assert confidence == 0.0

    def test_avatar_detection_by_structure(self):
        """Small + rounded + image fill = avatar."""
        node = _make_node(
            name="ProfileImage",  # No exact name match for avatar
            width=48.0,
            height=48.0,
            corner_radius=24.0,  # 50% of 48
            has_image_fill=True,
        )
        role, confidence = classify(node)
        assert role == "avatar"
        assert confidence == 0.78

    def test_avatar_too_large(self):
        """Nodes larger than 64px should not be classified as avatar."""
        node = _make_node(
            name="LargeImage",
            width=128.0,
            height=128.0,
            corner_radius=64.0,
            has_image_fill=True,
        )
        role, confidence = classify(node)
        assert role is None
        assert confidence == 0.0

    def test_avatar_not_rounded(self):
        """Square images without rounding should not be avatars."""
        node = _make_node(
            name="SquareThumb",
            width=48.0,
            height=48.0,
            corner_radius=4.0,  # < 50% of 48
            has_image_fill=True,
        )
        role, confidence = classify(node)
        assert role is None
        assert confidence == 0.0

    def test_data_table_detection_by_structure(self):
        """3+ frame children with uniform widths = data-table."""
        children = [
            _make_frame_child(width=400.0, node_id="r:1", name="Row1"),
            _make_frame_child(width=400.0, node_id="r:2", name="Row2"),
            _make_frame_child(width=400.0, node_id="r:3", name="Row3"),
        ]
        node = _make_node(name="ContentGrid", children=children)
        role, confidence = classify(node)
        assert role == "data-table"
        assert confidence == 0.78

    def test_data_table_not_enough_rows(self):
        """Fewer than 3 frame children should not classify as table."""
        children = [
            _make_frame_child(width=400.0, node_id="r:1", name="Row1"),
            _make_frame_child(width=400.0, node_id="r:2", name="Row2"),
        ]
        node = _make_node(name="SmallGrid", children=children)
        role, _ = classify(node)
        assert role is None

    def test_stepper_detection_by_structure(self):
        """Horizontal + 3 frames + 2 separators = stepper."""
        # Use varying widths so the data-table heuristic (uniform widths) doesn't match first
        children = [
            _make_frame_child(width=120.0, node_id="s:1", name="Step1"),
            _make_vector_child(node_id="a:1"),
            _make_frame_child(width=80.0, node_id="s:2", name="Step2"),
            _make_vector_child(node_id="a:2"),
            _make_frame_child(width=150.0, node_id="s:3", name="Step3"),
        ]
        node = _make_node(
            name="ProgressFlow",
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            children=children,
        )
        role, confidence = classify(node)
        assert role == "stepper"
        assert confidence == 0.78


# ---------------------------------------------------------------------------
# Tier 3 — Component property inference
# ---------------------------------------------------------------------------


class TestPropertyClassification:
    """Tier 3: component_property_definitions analysis."""

    def test_form_control_size_plus_variant(self):
        """size + variant properties → form-control."""
        node = _make_node(
            name="GenericComponent",
            component_property_definitions={
                "size": _make_prop_def(FigmaPropertyType.VARIANT, "medium"),
                "variant": _make_prop_def(FigmaPropertyType.VARIANT, "primary"),
            },
        )
        role, confidence = classify(node)
        assert role == "form-control"
        assert confidence == 0.72

    def test_selectable_checked_prop(self):
        """checked boolean property → selectable."""
        node = _make_node(
            name="ToggleItem",
            component_property_definitions={
                "checked": _make_prop_def(FigmaPropertyType.BOOLEAN, "false"),
            },
        )
        role, confidence = classify(node)
        assert role == "selectable"
        assert confidence == 0.72

    def test_selectable_isActive_prop(self):
        """isActive property → selectable."""
        node = _make_node(
            name="ListItem",
            component_property_definitions={
                "isActive": _make_prop_def(FigmaPropertyType.BOOLEAN, "false"),
            },
        )
        role, confidence = classify(node)
        assert role == "selectable"
        assert confidence == 0.72

    def test_no_matching_properties(self):
        """Properties without size/variant/selectable → no classification."""
        node = _make_node(
            name="PlainComponent",
            component_property_definitions={
                "label": _make_prop_def(FigmaPropertyType.TEXT, "Button"),
            },
        )
        role, confidence = classify(node)
        assert role is None
        assert confidence == 0.0

    def test_no_properties_at_all(self):
        """Node without component_property_definitions → no match."""
        node = _make_node(name="SimpleFrame")
        role, confidence = classify(node)
        assert role is None
        assert confidence == 0.0


# ---------------------------------------------------------------------------
# Tier priority — name wins over structure
# ---------------------------------------------------------------------------


class TestTierPriority:
    """Verify the cascade: name > structure > properties."""

    def test_name_overrides_structure(self):
        """Name match takes priority even when structure also matches."""
        node = _make_node(
            name="Pagination",  # Name match → 0.90
            has_auto_layout=True,
            layout_mode=LayoutMode.HORIZONTAL,
            children=[
                _make_vector_child(node_id="v:1"),
                _make_text_child("1", node_id="t:1"),
                _make_text_child("2", node_id="t:2"),
                _make_vector_child(node_id="v:2"),
            ],
        )
        role, confidence = classify(node)
        assert role == "pagination"
        assert confidence == 0.90  # Name confidence, not structural

    def test_structure_when_name_misses(self):
        """Structural match used when name doesn't match."""
        children = [
            _make_frame_child(width=400.0, node_id="r:1", name="Row1"),
            _make_frame_child(width=400.0, node_id="r:2", name="Row2"),
            _make_frame_child(width=400.0, node_id="r:3", name="Row3"),
        ]
        node = _make_node(name="UnknownLayout", children=children)
        role, confidence = classify(node)
        assert role == "data-table"
        assert confidence == 0.78


# ---------------------------------------------------------------------------
# Confidence threshold
# ---------------------------------------------------------------------------


class TestConfidenceThreshold:
    """Verify the 0.70 threshold is enforced."""

    def test_threshold_value(self):
        assert CONFIDENCE_THRESHOLD == 0.70

    def test_all_tiers_above_threshold(self):
        """All tier confidences must be >= CONFIDENCE_THRESHOLD."""
        assert 0.90 >= CONFIDENCE_THRESHOLD  # Tier 1
        assert 0.78 >= CONFIDENCE_THRESHOLD  # Tier 2
        assert 0.72 >= CONFIDENCE_THRESHOLD  # Tier 3


# ---------------------------------------------------------------------------
# annotate() — tree walk
# ---------------------------------------------------------------------------


class TestAnnotate:
    """Test the tree-walking annotate() function."""

    def test_annotate_sets_role_on_matching_node(self):
        """annotate() should set semantic_role if the field exists."""
        node = _make_node(name="Pagination")
        # FigmaIRNode may not have semantic_role yet — annotate uses hasattr.
        # We manually add it to test the setter.
        node.semantic_role = None  # type: ignore[attr-defined]
        node.semantic_confidence = 0.0  # type: ignore[attr-defined]
        result = annotate(node)
        assert result is node  # Returns same node
        assert node.semantic_role == "pagination"  # type: ignore[attr-defined]
        assert node.semantic_confidence == 0.90  # type: ignore[attr-defined]

    def test_annotate_walks_children(self):
        """annotate() should classify children recursively."""
        child = _make_node(node_id="c:1", name="Badge")
        child.semantic_role = None  # type: ignore[attr-defined]
        child.semantic_confidence = 0.0  # type: ignore[attr-defined]
        parent = _make_node(name="Container", children=[child])
        parent.semantic_role = None  # type: ignore[attr-defined]
        parent.semantic_confidence = 0.0  # type: ignore[attr-defined]

        annotate(parent)
        assert child.semantic_role == "badge"  # type: ignore[attr-defined]
        assert child.semantic_confidence == 0.90  # type: ignore[attr-defined]
        # Parent "Container" doesn't match any pattern
        assert parent.semantic_role is None  # type: ignore[attr-defined]

    def test_annotate_skips_missing_fields(self):
        """annotate() should not crash if semantic fields don't exist."""
        node = _make_node(name="Pagination")
        # Don't add semantic_role/semantic_confidence — hasattr should be False
        # on the dataclass (unless Task 1 added them)
        result = annotate(node)
        assert result is node  # Should not raise


# ---------------------------------------------------------------------------
# Backward compatibility
# ---------------------------------------------------------------------------


class TestBackwardCompatibility:
    """Verify semantic fields don't break existing IR behavior."""

    def test_no_semantic_fields_by_default(self):
        """FigmaIRNode without classification has semantic_role=None."""
        node = FigmaIRNode(node_id="default:1")
        assert node.semantic_role is None
        assert node.semantic_confidence is None

    def test_classify_does_not_mutate_node(self):
        """classify() returns a tuple but does NOT modify the node."""
        node = _make_node(name="Pagination")
        original_role = node.semantic_role

        classify(node)

        # classify() only returns — annotate() mutates
        assert node.semantic_role == original_role
