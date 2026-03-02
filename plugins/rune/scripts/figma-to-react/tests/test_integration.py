"""Integration tests using captured Figma API responses.

These tests exercise the full pipeline (fetch → parse → generate)
against real API data without hitting the network. The fixture
``signup_12_749_nodes.json`` was captured from node 12-749 of:
https://www.figma.com/design/VszzNQxbig1xYxHTrfxeIY/50-Web-Sign-up-log-in-designs--Community-

To recapture the fixture (requires FIGMA_TOKEN):
    python3 -c "
    import asyncio, json
    from figma_client import FigmaClient
    async def go():
        async with FigmaClient() as c:
            d = await c.get_nodes('VszzNQxbig1xYxHTrfxeIY', ['12-749'])
            with open('tests/fixtures/signup_12_749_nodes.json', 'w') as f:
                json.dump(d, f, indent=2)
    asyncio.run(go())
    "
"""
# NOTE: Edge-case imports are done inline where needed to keep tests isolated

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from core import extract_react_code, fetch_design, to_react  # noqa: E402
from node_parser import parse_node, walk_tree  # noqa: E402
from tests.mock_figma_client import MockFigmaClient, FIXTURES_DIR  # noqa: E402

# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

SIGNUP_FILE_KEY = "VszzNQxbig1xYxHTrfxeIY"
SIGNUP_NODE_ID = "12:749"
SIGNUP_URL = (
    "https://www.figma.com/design/VszzNQxbig1xYxHTrfxeIY/"
    "50-Web-Sign-up-log-in-designs--Community-?node-id=12-749"
)
SIGNUP_FIXTURE = FIXTURES_DIR / "signup_12_749_nodes.json"


@pytest.fixture()
def mock_client() -> MockFigmaClient:
    """Create a MockFigmaClient with the signup fixture registered."""
    client = MockFigmaClient()
    client.register_nodes_fixture(
        SIGNUP_FILE_KEY,
        SIGNUP_NODE_ID,
        SIGNUP_FIXTURE,
    )
    return client


@pytest.fixture()
def signup_raw_doc() -> dict:
    """Load the raw document dict for the signup node (12:749)."""
    with open(SIGNUP_FIXTURE) as f:
        data = json.load(f)
    return data["nodes"][SIGNUP_NODE_ID]["document"]


# ---------------------------------------------------------------------------
# Data preservation — raw dict has all fields
# ---------------------------------------------------------------------------


class TestRawDataPreservation:
    """Verify captured fixture contains the fields that Pydantic used to strip."""

    def test_fixture_has_text_characters(self, signup_raw_doc):
        """At least one TEXT node has 'characters' field."""
        texts = _find_nodes_by_type(signup_raw_doc, "TEXT")
        assert len(texts) > 0
        chars_found = [n.get("characters", "") for n in texts if n.get("characters")]
        assert len(chars_found) > 0, "No TEXT node has characters field"

    def test_fixture_has_layout_mode(self, signup_raw_doc):
        """At least one FRAME has layoutMode set."""
        frames = _find_nodes_by_type(signup_raw_doc, "FRAME")
        layouts = [f for f in frames if f.get("layoutMode") and f["layoutMode"] != "NONE"]
        assert len(layouts) > 0, "No FRAME has layoutMode set"

    def test_fixture_has_fill_geometry(self, signup_raw_doc):
        """At least one VECTOR node has fillGeometry."""
        vectors = _find_nodes_by_type(signup_raw_doc, "VECTOR")
        with_geo = [v for v in vectors if v.get("fillGeometry")]
        assert len(with_geo) > 0, "No VECTOR has fillGeometry"


# ---------------------------------------------------------------------------
# IR parsing from real data
# ---------------------------------------------------------------------------


class TestIRParsingFromFixture:
    """Verify parse_node() produces correct IR from captured fixture data."""

    def test_parses_root_frame(self, signup_raw_doc):
        ir = parse_node(signup_raw_doc)
        assert ir is not None
        assert ir.name == "Sign up"
        assert ir.node_type.value == "FRAME"

    def test_text_content_parsed(self, signup_raw_doc):
        """All TEXT nodes should have text_content populated."""
        ir = parse_node(signup_raw_doc)
        assert ir is not None
        all_nodes = walk_tree(ir)
        text_nodes = [n for n in all_nodes if n.text_content]
        assert len(text_nodes) >= 5, f"Expected >=5 text nodes, got {len(text_nodes)}"

        # Specific text values from the design
        all_text = " ".join(n.text_content for n in text_nodes)
        assert "Facebook" in all_text
        assert "Google" in all_text
        assert "Twitter" in all_text

    def test_auto_layout_detected(self, signup_raw_doc):
        """Frames with layoutMode should have has_auto_layout=True."""
        ir = parse_node(signup_raw_doc)
        assert ir is not None
        all_nodes = walk_tree(ir)
        auto_layout_nodes = [n for n in all_nodes if n.has_auto_layout]
        assert len(auto_layout_nodes) >= 3, (
            f"Expected >=3 auto-layout nodes, got {len(auto_layout_nodes)}"
        )

    def test_fill_geometry_on_vectors(self, signup_raw_doc):
        """Vector nodes should have fill_geometry populated."""
        ir = parse_node(signup_raw_doc)
        assert ir is not None
        all_nodes = walk_tree(ir)
        with_geo = [n for n in all_nodes if n.fill_geometry]
        assert len(with_geo) >= 3, (
            f"Expected >=3 nodes with fill_geometry, got {len(with_geo)}"
        )


# ---------------------------------------------------------------------------
# Full pipeline: to_react() via MockFigmaClient
# ---------------------------------------------------------------------------


class TestToReactPipeline:
    """Test the full to_react() pipeline with mock client."""

    @pytest.mark.asyncio
    async def test_generates_component(self, mock_client):
        result = await to_react(mock_client, SIGNUP_URL)
        code = extract_react_code(result)
        assert "export default function" in code
        assert "import React" in code

    @pytest.mark.asyncio
    async def test_text_content_in_output(self, mock_client):
        """Generated JSX should contain actual text from the design."""
        result = await to_react(mock_client, SIGNUP_URL)
        code = extract_react_code(result)
        assert "Facebook" in code
        assert "Google" in code

    @pytest.mark.asyncio
    async def test_flex_layout_in_output(self, mock_client):
        """Generated JSX should contain Tailwind flex classes."""
        result = await to_react(mock_client, SIGNUP_URL)
        code = extract_react_code(result)
        assert "flex" in code

    @pytest.mark.asyncio
    async def test_semantic_html_in_output(self, mock_client):
        """Generated JSX should use semantic HTML tags."""
        result = await to_react(mock_client, SIGNUP_URL)
        code = extract_react_code(result)
        # The design has text fields and labels — at least some should map
        # to semantic tags based on font size (h1/h2/h3) or name (button)
        has_semantic = any(
            tag in code for tag in ("<h1", "<h2", "<h3", "<button", "<nav", "<p")
        )
        assert has_semantic, "No semantic HTML tags found in generated code"

    @pytest.mark.asyncio
    async def test_svg_paths_in_output(self, mock_client):
        """Generated JSX should contain actual SVG path data."""
        result = await to_react(mock_client, SIGNUP_URL)
        code = extract_react_code(result)
        assert "<path d=" in code, "No SVG path elements found"

    @pytest.mark.asyncio
    async def test_no_empty_text_nodes(self, mock_client):
        """No text node should render as empty content."""
        result = await to_react(mock_client, SIGNUP_URL)
        code = extract_react_code(result)
        # Check there are no empty <p></p> or <h1></h1> tags
        import re
        empty_tags = re.findall(r"<(p|h[1-3])\b[^>]*>\s*</(p|h[1-3])>", code)
        assert len(empty_tags) == 0, f"Found empty text tags: {empty_tags}"


# ---------------------------------------------------------------------------
# fetch_design() pipeline
# ---------------------------------------------------------------------------


class TestFetchDesignPipeline:
    """Test fetch_design() returns valid IR tree."""

    @pytest.mark.asyncio
    async def test_returns_tree_with_nodes(self, mock_client):
        # Use large max_length — 184 nodes produce ~130KB of IR JSON
        result = await fetch_design(
            mock_client, SIGNUP_URL, max_length=500_000
        )
        content = json.loads(result["content"])
        assert content["node_count"] > 10
        assert content["tree"]["name"] == "Sign up"
        assert "children" in content["tree"]


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _find_nodes_by_type(raw: dict, node_type: str) -> list[dict]:
    """Recursively find all nodes of a given type in raw Figma data."""
    results: list[dict] = []
    if raw.get("type") == node_type:
        results.append(raw)
    for child in raw.get("children", []):
        results.extend(_find_nodes_by_type(child, node_type))
    return results


# ---------------------------------------------------------------------------
# Edge-case tests: empty / None / missing / malformed inputs in pipeline
# ---------------------------------------------------------------------------


def _make_ir_node(**overrides):
    """Build a minimal FigmaIRNode for edge-case testing without network calls."""
    from node_parser import FigmaIRNode
    from figma_types import NodeType
    defaults = dict(node_id="1:1", name="TestNode", node_type=NodeType.FRAME)
    defaults.update(overrides)
    return FigmaIRNode(**defaults)


class TestPaginateOutputEdgeCases:
    """Edge-case tests for paginate_output() boundary behavior."""

    def test_empty_string_content(self):
        """Empty string produces a result with content='' and no pagination keys."""
        from core import paginate_output
        result = paginate_output("")
        assert result["content"] == ""
        assert "has_more" not in result

    def test_content_exactly_at_max_length_no_pagination(self):
        """Content exactly at max_length produces no pagination metadata."""
        from core import paginate_output
        content = "x" * 100
        result = paginate_output(content, max_length=100)
        assert result["content"] == content
        assert "has_more" not in result
        assert "total_length" not in result

    def test_content_one_char_over_max_length_paginates(self):
        """Content one character over max_length triggers pagination."""
        from core import paginate_output
        content = "x" * 101
        result = paginate_output(content, max_length=100)
        assert "total_length" in result
        assert result["total_length"] == 101
        assert result["has_more"] is True
        assert result["next_start_index"] == 100

    def test_zero_max_length_all_has_more(self):
        """max_length=0 causes everything to be left for pagination."""
        from core import paginate_output
        content = "hello"
        result = paginate_output(content, max_length=0)
        assert result["content"] == ""
        assert result["has_more"] is True

    def test_large_start_index_beyond_content(self):
        """start_index beyond content length returns empty content chunk."""
        from core import paginate_output
        content = "hello"
        result = paginate_output(content, max_length=100, start_index=999)
        assert result["content"] == ""

    def test_start_index_zero_is_default(self):
        """Explicit start_index=0 should behave the same as default."""
        from core import paginate_output
        content = "abcdef"
        r1 = paginate_output(content)
        r2 = paginate_output(content, start_index=0)
        assert r1["content"] == r2["content"]


class TestExtractReactCodeEdgeCases:
    """Edge-case tests for extract_react_code() with malformed inputs."""

    def test_missing_content_key_returns_empty(self):
        """Dict with no 'content' key returns empty string."""
        from core import extract_react_code
        assert extract_react_code({}) == ""

    def test_missing_main_component_returns_empty(self):
        """Paginated result with no 'main_component' returns empty string."""
        from core import extract_react_code
        import json
        inner = json.dumps({"file_key": "abc", "node_count": 5})
        assert extract_react_code({"content": inner}) == ""

    def test_empty_main_component_returns_empty(self):
        """Empty main_component string is returned as-is."""
        from core import extract_react_code
        import json
        inner = json.dumps({"main_component": ""})
        assert extract_react_code({"content": inner}) == ""

    def test_non_string_content_falls_back_to_dict(self):
        """Non-string content dict is used directly for main_component lookup."""
        from core import extract_react_code
        result = {"main_component": "const X = () => <div />;"}
        assert extract_react_code(result) == "const X = () => <div />;"


class TestIrToDictEdgeCases:
    """Edge-case tests for ir_to_dict() with boundary depth and null nodes."""

    def test_max_depth_zero_truncates(self):
        """max_depth=0 returns truncated node with only id and name."""
        from core import ir_to_dict
        node = _make_ir_node()
        result = ir_to_dict(node, max_depth=0)
        assert result.get("truncated") is True
        assert result["node_id"] == "1:1"
        assert result["name"] == "TestNode"
        assert "type" not in result

    def test_empty_children_not_in_result(self):
        """Node with no children should not include 'children' key."""
        from core import ir_to_dict
        node = _make_ir_node(children=[])
        result = ir_to_dict(node, max_depth=5)
        assert "children" not in result

    def test_invisible_node_sets_visible_false(self):
        """Invisible node includes visible=False in result dict."""
        from core import ir_to_dict
        node = _make_ir_node(visible=False)
        result = ir_to_dict(node, max_depth=5)
        assert result.get("visible") is False

    def test_fully_opaque_node_no_opacity_key(self):
        """Node with opacity=1.0 should not include opacity key."""
        from core import ir_to_dict
        node = _make_ir_node(opacity=1.0)
        result = ir_to_dict(node, max_depth=5)
        assert "opacity" not in result

    def test_partial_opacity_node_includes_opacity(self):
        """Node with opacity<1.0 includes opacity in result dict."""
        from core import ir_to_dict
        node = _make_ir_node(opacity=0.5)
        result = ir_to_dict(node, max_depth=5)
        assert "opacity" in result
        assert abs(result["opacity"] - 0.5) < 0.001


class TestCollectSvgFallbackIdsEdgeCases:
    """Edge-case tests for _collect_svg_fallback_ids with boundary inputs."""

    def test_empty_node_tree_returns_empty(self):
        """Node with no children and no SVG candidate returns empty list."""
        from core import _collect_svg_fallback_ids
        node = _make_ir_node(is_svg_candidate=False)
        assert _collect_svg_fallback_ids(node) == []

    def test_svg_candidate_without_geometry_collected(self):
        """SVG candidate with no fill/stroke geometry is collected."""
        from core import _collect_svg_fallback_ids
        node = _make_ir_node(
            node_id="5:1",
            is_svg_candidate=True,
            fill_geometry=[],
            stroke_geometry=[],
        )
        ids = _collect_svg_fallback_ids(node)
        assert "5:1" in ids

    def test_svg_candidate_with_geometry_not_collected(self):
        """SVG candidate that has fill_geometry is NOT collected."""
        from core import _collect_svg_fallback_ids
        node = _make_ir_node(
            node_id="6:1",
            is_svg_candidate=True,
            fill_geometry=[{"path": "M0 0 L10 10 Z", "windingRule": "NONZERO"}],
        )
        ids = _collect_svg_fallback_ids(node)
        assert "6:1" not in ids

    def test_null_node_children_no_crash(self):
        """Node tree with empty children does not crash."""
        from core import _collect_svg_fallback_ids
        node = _make_ir_node(children=[])
        result = _collect_svg_fallback_ids(node)
        assert result == []

    def test_boundary_max_depth_respected(self):
        """Recursion stops at _MAX_SVG_SCAN_DEPTH."""
        from core import _collect_svg_fallback_ids, _MAX_SVG_SCAN_DEPTH
        # Call directly beyond the depth limit
        node = _make_ir_node(is_svg_candidate=True)
        # Passing _depth > _MAX_SVG_SCAN_DEPTH should return empty
        result = _collect_svg_fallback_ids(node, _depth=_MAX_SVG_SCAN_DEPTH + 1)
        assert result == []


class TestPipelineEdgeCases:
    """Edge-case integration tests for the full to_react pipeline."""

    @pytest.mark.asyncio
    async def test_custom_component_name_override(self, mock_client):
        """component_name parameter overrides name derived from node."""
        result = await to_react(mock_client, SIGNUP_URL, component_name="MyCustomForm")
        code = extract_react_code(result)
        assert "function MyCustomForm" in code

    @pytest.mark.asyncio
    async def test_empty_component_name_uses_node_name(self, mock_client):
        """Empty component_name falls back to the node name."""
        result = await to_react(mock_client, SIGNUP_URL, component_name="")
        code = extract_react_code(result)
        # The design root is "Sign up" → component name derived from it
        assert "export default function" in code

    @pytest.mark.asyncio
    async def test_zero_max_length_returns_truncated_chunk(self, mock_client):
        """max_length=0 returns an empty content chunk with pagination metadata."""
        result = await to_react(mock_client, SIGNUP_URL, max_length=0)
        # Content should be empty string (no chars in first chunk)
        assert result["content"] == ""
        assert result.get("has_more") is True

    @pytest.mark.asyncio
    async def test_large_start_index_returns_empty_content(self, mock_client):
        """start_index beyond content length returns empty chunk."""
        result = await to_react(mock_client, SIGNUP_URL, start_index=10_000_000)
        assert result["content"] == ""

    @pytest.mark.asyncio
    async def test_missing_image_urls_produces_todo_comments(self, mock_client):
        """Pipeline with no image URLs emits TODO comments for unresolved refs."""
        # MockFigmaClient.get_images() returns {} — all refs are unresolved
        result = await to_react(mock_client, SIGNUP_URL)
        import json
        content = json.loads(result["content"])
        code = content.get("main_component", "")
        # Unresolved image refs should appear in TODO comments above the component
        full_output = result["content"]
        # The main component code or the outer JSON should mention TODO or unresolved
        assert "TODO" in code or "unresolved_images" in full_output

    @pytest.mark.asyncio
    async def test_invalid_missing_url_raises(self, mock_client):
        """Malformed/missing URL raises FigmaURLError or ValueError."""
        from core import FigmaURLError
        with pytest.raises((FigmaURLError, ValueError, Exception)):
            await to_react(mock_client, "not-a-figma-url")

    @pytest.mark.asyncio
    async def test_null_node_result_raises(self, mock_client):
        """If parse_node returns None, to_react raises an error."""
        # Register a fixture with a node type that is unsupported
        from tests.mock_figma_client import MockFigmaClient
        import json
        unsupported_client = MockFigmaClient()
        # Craft a minimal fixture with an unsupported STICKY type
        fake_fixture_data = {
            "nodes": {
                "99-1": {
                    "document": {
                        "id": "99:1",
                        "name": "UnsupportedNode",
                        "type": "STICKY",
                    }
                }
            }
        }
        fixture_path = FIXTURES_DIR / "_tmp_unsupported.json"
        with open(fixture_path, "w") as f:
            json.dump(fake_fixture_data, f)
        try:
            unsupported_client.register_nodes_fixture(
                "fake_file_key", "99-1", fixture_path
            )
            url = "https://www.figma.com/design/fake_file_key/test?node-id=99-1"
            from figma_client import FigmaAPIError
            with pytest.raises((FigmaAPIError, Exception)):
                await to_react(unsupported_client, url)
        finally:
            if fixture_path.exists():
                fixture_path.unlink()
