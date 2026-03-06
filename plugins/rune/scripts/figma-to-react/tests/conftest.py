"""Shared fixtures for figma-to-react test suite."""
from __future__ import annotations

import importlib
import json
import sys
import types
from pathlib import Path

import pytest

# ---------------------------------------------------------------------------
# Package bootstrap
# ---------------------------------------------------------------------------
# The figma-to-react directory uses relative imports (e.g., from .figma_types)
# but has a hyphenated name that prevents normal Python package import.
# We create a synthetic package so that relative imports resolve correctly.

_PKG_DIR = Path(__file__).resolve().parent.parent
_PKG_NAME = "figma_to_react"

if _PKG_NAME not in sys.modules:
    # Create a package module and register it
    pkg = types.ModuleType(_PKG_NAME)
    pkg.__path__ = [str(_PKG_DIR)]
    pkg.__file__ = str(_PKG_DIR / "__init__.py")
    pkg.__package__ = _PKG_NAME
    sys.modules[_PKG_NAME] = pkg

# Add the package directory to sys.path so bare imports also work
if str(_PKG_DIR) not in sys.path:
    sys.path.insert(0, str(_PKG_DIR))

# Now pre-import the key modules so that their relative imports resolve
# against the synthetic package. Tests can then do:
#   from node_parser import parse_node
# and it will work because node_parser is loaded as figma_to_react.node_parser.
for _mod_name in [
    "figma_types",
    "url_parser",
    "figma_client",
    "node_parser",
    "style_builder",
    "tailwind_mapper",
    "image_handler",
    "layout_resolver",
    "react_generator",
    "core",
    "cli",
]:
    _mod_path = _PKG_DIR / f"{_mod_name}.py"
    if _mod_path.exists():
        _full_name = f"{_PKG_NAME}.{_mod_name}"
        if _full_name not in sys.modules:
            spec = importlib.util.spec_from_file_location(
                _full_name, str(_mod_path),
                submodule_search_locations=[],
            )
            if spec and spec.loader:
                mod = importlib.util.module_from_spec(spec)
                mod.__package__ = _PKG_NAME
                sys.modules[_full_name] = mod
                # Also register under bare name for convenience
                sys.modules[_mod_name] = mod
                spec.loader.exec_module(mod)


FIXTURES_DIR = Path(__file__).parent / "fixtures"


@pytest.fixture()
def sample_figma_response() -> dict:
    """Load the sample Figma API response fixture."""
    with open(FIXTURES_DIR / "sample_figma_response.json") as f:
        return json.load(f)


@pytest.fixture()
def hero_card_node(sample_figma_response: dict) -> dict:
    """Extract the HeroCard frame node from the sample response."""
    return sample_figma_response["document"]["children"][0]["children"][0]


@pytest.fixture()
def text_node(sample_figma_response: dict) -> dict:
    """Extract the CardTitle text node."""
    hero = sample_figma_response["document"]["children"][0]["children"][0]
    return hero["children"][1]  # CardTitle


@pytest.fixture()
def mixed_text_node(sample_figma_response: dict) -> dict:
    """Extract the MixedText node with characterStyleOverrides."""
    page = sample_figma_response["document"]["children"][0]
    # MixedText is at index 7 in page children (id 8:1)
    for child in page["children"]:
        if child["id"] == "8:1":
            return child
    raise ValueError("MixedText node not found in fixture")


@pytest.fixture()
def image_rect_node(sample_figma_response: dict) -> dict:
    """Extract the CardImage rectangle with IMAGE fill."""
    hero = sample_figma_response["document"]["children"][0]["children"][0]
    return hero["children"][0]  # CardImage


@pytest.fixture()
def vector_node(sample_figma_response: dict) -> dict:
    """Extract the IconSmall vector node."""
    page = sample_figma_response["document"]["children"][0]
    for child in page["children"]:
        if child["id"] == "2:1":
            return child
    raise ValueError("Vector node not found in fixture")


@pytest.fixture()
def ellipse_node(sample_figma_response: dict) -> dict:
    """Extract the CircleBadge ellipse node."""
    page = sample_figma_response["document"]["children"][0]
    for child in page["children"]:
        if child["id"] == "3:1":
            return child
    raise ValueError("Ellipse node not found in fixture")


@pytest.fixture()
def group_node(sample_figma_response: dict) -> dict:
    """Extract the GroupedElements group node."""
    page = sample_figma_response["document"]["children"][0]
    for child in page["children"]:
        if child["id"] == "4:1":
            return child
    raise ValueError("Group node not found in fixture")


@pytest.fixture()
def boolean_op_node(sample_figma_response: dict) -> dict:
    """Extract the BoolUnion boolean operation node."""
    page = sample_figma_response["document"]["children"][0]
    for child in page["children"]:
        if child["id"] == "5:1":
            return child
    raise ValueError("Boolean operation node not found in fixture")


@pytest.fixture()
def component_node(sample_figma_response: dict) -> dict:
    """Extract the MyComponent component node."""
    page = sample_figma_response["document"]["children"][0]
    for child in page["children"]:
        if child["id"] == "6:1":
            return child
    raise ValueError("Component node not found in fixture")


@pytest.fixture()
def section_node(sample_figma_response: dict) -> dict:
    """Extract the ContentSection section node."""
    page = sample_figma_response["document"]["children"][0]
    for child in page["children"]:
        if child["id"] == "7:1":
            return child
    raise ValueError("Section node not found in fixture")


@pytest.fixture()
def instance_node(sample_figma_response: dict) -> dict:
    """Extract the MyComponentInstance instance node."""
    page = sample_figma_response["document"]["children"][0]
    for child in page["children"]:
        if child["id"] == "11:1":
            return child
    raise ValueError("Instance node not found in fixture")


@pytest.fixture()
def grid_frame_node(sample_figma_response: dict) -> dict:
    """Extract the GridLayout frame node with GRID layoutMode."""
    page = sample_figma_response["document"]["children"][0]
    for child in page["children"]:
        if child["id"] == "9:1":
            return child
    raise ValueError("Grid frame node not found in fixture")


@pytest.fixture()
def gradient_rect_node(sample_figma_response: dict) -> dict:
    """Extract the GradientBox rectangle with gradient fill and stroke."""
    page = sample_figma_response["document"]["children"][0]
    for child in page["children"]:
        if child["id"] == "10:1":
            return child
    raise ValueError("Gradient rect node not found in fixture")
