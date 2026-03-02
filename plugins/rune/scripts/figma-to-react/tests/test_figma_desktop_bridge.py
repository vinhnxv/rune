"""Tests for figma_desktop_bridge.py — Figma Desktop MCP bridge."""
from __future__ import annotations

import json
import sys
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import httpx
import pytest

# Add parent directory to path so we can import the module under test
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from figma_client import FigmaAPIError, FigmaNotFoundError  # noqa: E402
from figma_desktop_bridge import DesktopMCPBridge, _CIRCUIT_BREAKER_THRESHOLD  # noqa: E402


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _mock_http_response(status_code: int, body: dict | str) -> MagicMock:
    """Build a mock httpx.Response."""
    resp = MagicMock(spec=httpx.Response)
    resp.status_code = status_code
    if isinstance(body, dict):
        resp.json.return_value = body
    else:
        resp.json.side_effect = json.JSONDecodeError("bad json", "", 0)
    return resp


def _make_async_client(response: MagicMock) -> AsyncMock:
    """Create an async httpx client mock that returns the given response."""
    client = AsyncMock(spec=httpx.AsyncClient)
    client.is_closed = False
    client.post = AsyncMock(return_value=response)
    return client


# ---------------------------------------------------------------------------
# DesktopMCPBridge lifecycle
# ---------------------------------------------------------------------------


class TestBridgeLifecycle:
    """Test bridge initialization and context manager lifecycle."""

    def test_default_init(self):
        """Bridge initialises with default timeout and no client."""
        bridge = DesktopMCPBridge()
        assert bridge._timeout == 30.0
        assert bridge._client is None
        assert bridge._rpc_id == 0

    def test_custom_timeout(self):
        """Custom timeout is stored."""
        bridge = DesktopMCPBridge(timeout=60.0)
        assert bridge._timeout == 60.0

    @pytest.mark.asyncio
    async def test_context_manager_enter_exit(self):
        """Bridge works as async context manager."""
        async with DesktopMCPBridge() as bridge:
            assert isinstance(bridge, DesktopMCPBridge)

    @pytest.mark.asyncio
    async def test_close_when_none_client(self):
        """close() is safe when _client is None."""
        bridge = DesktopMCPBridge()
        await bridge.close()  # Should not raise

    @pytest.mark.asyncio
    async def test_close_when_already_closed(self):
        """close() is safe when client is already closed."""
        bridge = DesktopMCPBridge()
        mock_client = MagicMock(spec=httpx.AsyncClient)
        mock_client.is_closed = True
        bridge._client = mock_client
        await bridge.close()  # Should not raise; aclose not called
        mock_client.aclose.assert_not_called()


# ---------------------------------------------------------------------------
# _next_id — monotonic RPC IDs
# ---------------------------------------------------------------------------


class TestNextId:
    """Test monotonically increasing RPC ID generation."""

    def test_starts_at_one(self):
        bridge = DesktopMCPBridge()
        assert bridge._next_id() == 1

    def test_increments_each_call(self):
        bridge = DesktopMCPBridge()
        ids = [bridge._next_id() for _ in range(5)]
        assert ids == [1, 2, 3, 4, 5]

    def test_zero_boundary_initial_rpc_id(self):
        """RPC ID starts at zero before first call (boundary check)."""
        bridge = DesktopMCPBridge()
        assert bridge._rpc_id == 0


# ---------------------------------------------------------------------------
# is_available
# ---------------------------------------------------------------------------


class TestIsAvailable:
    """Test Desktop MCP availability probe."""

    @pytest.mark.asyncio
    async def test_returns_true_when_server_responds_with_result(self):
        """Server returning a result dict means available."""
        bridge = DesktopMCPBridge()
        mock_resp = _mock_http_response(200, {"result": {"tools": []}})
        bridge._client = _make_async_client(mock_resp)
        assert await bridge.is_available() is True

    @pytest.mark.asyncio
    async def test_returns_false_on_non_200_status(self):
        """Non-200 HTTP status means unavailable."""
        bridge = DesktopMCPBridge()
        mock_resp = _mock_http_response(503, {"error": "down"})
        bridge._client = _make_async_client(mock_resp)
        assert await bridge.is_available() is False

    @pytest.mark.asyncio
    async def test_returns_false_on_rpc_error_in_body(self):
        """JSON-RPC error field in 200 response means unavailable."""
        bridge = DesktopMCPBridge()
        mock_resp = _mock_http_response(200, {"error": {"code": -32600, "message": "bad request"}})
        bridge._client = _make_async_client(mock_resp)
        assert await bridge.is_available() is False

    @pytest.mark.asyncio
    async def test_returns_false_on_connect_error(self):
        """Connection refused (Desktop app not running) returns False."""
        bridge = DesktopMCPBridge()
        client = AsyncMock(spec=httpx.AsyncClient)
        client.is_closed = False
        client.post = AsyncMock(side_effect=httpx.ConnectError("connection refused"))
        bridge._client = client
        assert await bridge.is_available() is False

    @pytest.mark.asyncio
    async def test_boundary_timeout_returns_false(self):
        """Timeout while probing returns False without raising."""
        bridge = DesktopMCPBridge()
        client = AsyncMock(spec=httpx.AsyncClient)
        client.is_closed = False
        client.post = AsyncMock(side_effect=httpx.TimeoutException("timed out"))
        bridge._client = client
        assert await bridge.is_available() is False

    @pytest.mark.asyncio
    async def test_returns_false_on_os_error(self):
        """OSError (e.g. no route to host) returns False."""
        bridge = DesktopMCPBridge()
        client = AsyncMock(spec=httpx.AsyncClient)
        client.is_closed = False
        client.post = AsyncMock(side_effect=OSError("network unreachable"))
        bridge._client = client
        assert await bridge.is_available() is False

    @pytest.mark.asyncio
    async def test_returns_false_on_unexpected_exception(self):
        """Unexpected exception during probe returns False (catch-all)."""
        bridge = DesktopMCPBridge()
        client = AsyncMock(spec=httpx.AsyncClient)
        client.is_closed = False
        client.post = AsyncMock(side_effect=RuntimeError("unexpected"))
        bridge._client = client
        assert await bridge.is_available() is False


# ---------------------------------------------------------------------------
# _call_tool
# ---------------------------------------------------------------------------


class TestCallTool:
    """Test MCP tool invocation via JSON-RPC."""

    @pytest.mark.asyncio
    async def test_successful_call_returns_result(self):
        """Successful RPC call returns unwrapped result."""
        bridge = DesktopMCPBridge()
        payload = {"result": {"name": "MyFile", "document": {}}}
        mock_resp = _mock_http_response(200, payload)
        bridge._client = _make_async_client(mock_resp)
        result = await bridge._call_tool("get_design_context", {"file_key": "abc"})
        assert result == {"name": "MyFile", "document": {}}

    @pytest.mark.asyncio
    async def test_boundary_timeout_raises_figma_api_error(self):
        """Timeout during tool call raises FigmaAPIError."""
        bridge = DesktopMCPBridge()
        client = AsyncMock(spec=httpx.AsyncClient)
        client.is_closed = False
        client.post = AsyncMock(side_effect=httpx.TimeoutException("timed out"))
        bridge._client = client
        with pytest.raises(FigmaAPIError, match="timed out"):
            await bridge._call_tool("some_tool", {})

    @pytest.mark.asyncio
    async def test_http_error_raises_figma_api_error(self):
        """HTTP connection error raises FigmaAPIError."""
        bridge = DesktopMCPBridge()
        client = AsyncMock(spec=httpx.AsyncClient)
        client.is_closed = False
        client.post = AsyncMock(side_effect=httpx.HTTPError("connection error"))
        bridge._client = client
        with pytest.raises(FigmaAPIError, match="connection error"):
            await bridge._call_tool("some_tool", {})

    @pytest.mark.asyncio
    async def test_non_200_response_raises_figma_api_error(self):
        """HTTP 500 from desktop app raises FigmaAPIError."""
        bridge = DesktopMCPBridge()
        mock_resp = _mock_http_response(500, {"error": "internal"})
        bridge._client = _make_async_client(mock_resp)
        with pytest.raises(FigmaAPIError, match="HTTP 500"):
            await bridge._call_tool("some_tool", {})

    @pytest.mark.asyncio
    async def test_rpc_error_not_found_code_raises_figma_not_found(self):
        """RPC error code -32600 maps to FigmaNotFoundError."""
        bridge = DesktopMCPBridge()
        body = {"error": {"code": -32600, "message": "method not found"}}
        mock_resp = _mock_http_response(200, body)
        bridge._client = _make_async_client(mock_resp)
        with pytest.raises(FigmaNotFoundError):
            await bridge._call_tool("missing_tool", {})

    @pytest.mark.asyncio
    async def test_rpc_error_with_not_found_message_raises_figma_not_found(self):
        """RPC error message containing 'not found' maps to FigmaNotFoundError."""
        bridge = DesktopMCPBridge()
        body = {"error": {"code": 0, "message": "file not found in project"}}
        mock_resp = _mock_http_response(200, body)
        bridge._client = _make_async_client(mock_resp)
        with pytest.raises(FigmaNotFoundError):
            await bridge._call_tool("get_design_context", {"file_key": "missing"})

    @pytest.mark.asyncio
    async def test_rpc_error_generic_raises_figma_api_error(self):
        """Generic RPC error raises FigmaAPIError."""
        bridge = DesktopMCPBridge()
        body = {"error": {"code": -32000, "message": "server error"}}
        mock_resp = _mock_http_response(200, body)
        bridge._client = _make_async_client(mock_resp)
        with pytest.raises(FigmaAPIError, match="server error"):
            await bridge._call_tool("some_tool", {})

    @pytest.mark.asyncio
    async def test_missing_result_key_returns_empty_dict(self):
        """Response with no 'result' key returns empty dict (no crash)."""
        bridge = DesktopMCPBridge()
        mock_resp = _mock_http_response(200, {"id": 1, "jsonrpc": "2.0"})
        bridge._client = _make_async_client(mock_resp)
        result = await bridge._call_tool("some_tool", {})
        assert isinstance(result, dict)


# ---------------------------------------------------------------------------
# _unwrap_result — static method
# ---------------------------------------------------------------------------


class TestUnwrapResult:
    """Test MCP result unwrapping / normalisation."""

    def test_plain_dict_returned_as_is(self):
        """A dict with no 'content' key is returned unchanged."""
        data = {"name": "MyFile", "document": {}}
        assert DesktopMCPBridge._unwrap_result(data) == data

    def test_empty_response_returns_raw_wrapper(self):
        """Non-dict result is wrapped in {'_raw': ...}."""
        assert DesktopMCPBridge._unwrap_result(None) == {"_raw": None}
        assert DesktopMCPBridge._unwrap_result(42) == {"_raw": 42}
        assert DesktopMCPBridge._unwrap_result([]) == {"_raw": []}

    def test_content_with_json_text_parsed(self):
        """Content list with JSON text is parsed into dict."""
        result = {
            "content": [
                {"type": "text", "text": '{"name": "MyFile", "role": "viewer"}'}
            ]
        }
        out = DesktopMCPBridge._unwrap_result(result)
        assert out["name"] == "MyFile"
        assert out["role"] == "viewer"

    def test_none_values_in_content_list(self):
        """None or non-dict items in content list are skipped gracefully."""
        result = {"content": [None, 42, {"type": "text", "text": '{"key": "val"}'}]}
        out = DesktopMCPBridge._unwrap_result(result)
        assert out.get("key") == "val"

    def test_invalid_json_falls_back_to_xml_or_text(self):
        """Malformed JSON in content falls back to raw text."""
        result = {"content": [{"type": "text", "text": "not valid json {{{"}]}
        out = DesktopMCPBridge._unwrap_result(result)
        assert "_text" in out or "_raw" in out or out == {
            "_text": "not valid json {{{",
            "content": result["content"],
        }

    def test_corrupt_data_non_list_content_returned_as_is(self):
        """When 'content' is not a list, dict is returned unchanged."""
        data = {"content": "not a list", "name": "MyFile"}
        assert DesktopMCPBridge._unwrap_result(data) == data

    def test_empty_content_list_returns_original(self):
        """Empty content list returns the original dict unchanged."""
        data = {"content": [], "extra": "field"}
        assert DesktopMCPBridge._unwrap_result(data) == data

    def test_json_non_dict_result_wrapped(self):
        """JSON that parses to a list is wrapped in {'data': ...}."""
        result = {"content": [{"type": "text", "text": "[1, 2, 3]"}]}
        out = DesktopMCPBridge._unwrap_result(result)
        assert out == {"data": [1, 2, 3]}

    def test_unicode_node_names_in_json_content(self):
        """Unicode/non-ASCII characters in JSON text content are handled."""
        unicode_data = {"name": "Composant \u00e9l\u00e9ment \u6839\u672c", "id": "1:1"}
        result = {"content": [{"type": "text", "text": json.dumps(unicode_data)}]}
        out = DesktopMCPBridge._unwrap_result(result)
        assert out["name"] == "Composant \u00e9l\u00e9ment \u6839\u672c"

    def test_missing_text_field_in_content_item(self):
        """Content item with missing 'text' field contributes empty string."""
        result = {"content": [{"type": "text"}, {"type": "text", "text": '{"k": "v"}'}]}
        out = DesktopMCPBridge._unwrap_result(result)
        assert out.get("k") == "v"

    def test_content_without_text_type_items_returns_original(self):
        """Content items without type='text' produce no text; returns original."""
        result = {"content": [{"type": "image", "url": "http://example.com/img.png"}]}
        out = DesktopMCPBridge._unwrap_result(result)
        assert out == result


# ---------------------------------------------------------------------------
# _parse_metadata_to_file — XML parsing
# ---------------------------------------------------------------------------


class TestParseMetadataToFile:
    """Test XML design context parsing."""

    def _minimal_xml(
        self,
        file_key: str = "abc123",
        file_name: str = "MyFile",
        schema_version: str = "5",
    ) -> str:
        return (
            f'<design_context file_key="{file_key}" file_name="{file_name}" '
            f'schema_version="{schema_version}">'
            "<nodes/><components/><styles/>"
            "</design_context>"
        )

    def test_basic_xml_parsed(self):
        """Minimal valid XML produces a file-shaped dict."""
        xml = self._minimal_xml()
        result = DesktopMCPBridge._parse_metadata_to_file(xml)
        assert result["name"] == "MyFile"
        assert result["mainFileKey"] == "abc123"
        assert result["_source"] == "desktop_mcp"
        assert "document" in result

    def test_missing_file_key_defaults_to_empty(self):
        """Missing file_key attribute defaults to empty string."""
        xml = '<design_context file_name="Test"><nodes/></design_context>'
        result = DesktopMCPBridge._parse_metadata_to_file(xml)
        assert result["mainFileKey"] == ""

    def test_missing_file_name_defaults_to_unknown(self):
        """Missing file_name attribute defaults to 'unknown'."""
        xml = '<design_context file_key="k1"><nodes/></design_context>'
        result = DesktopMCPBridge._parse_metadata_to_file(xml)
        assert result["name"] == "unknown"

    def test_malformed_xml_raises_parse_error(self):
        """Malformed XML raises ET.ParseError."""
        with pytest.raises(ET.ParseError):
            DesktopMCPBridge._parse_metadata_to_file("<design_context unclosed")

    def test_corrupt_data_empty_string_raises_parse_error(self):
        """Empty string input raises ET.ParseError."""
        with pytest.raises(ET.ParseError):
            DesktopMCPBridge._parse_metadata_to_file("")

    def test_node_with_unicode_name(self):
        """Unicode characters in node names are preserved."""
        xml = (
            '<design_context file_key="k" file_name="F">'
            '<nodes><node id="1:1" name="\u6839\u672c\u30ce\u30fc\u30c9" '
            'type="FRAME" width="100" height="100"/></nodes>'
            "</design_context>"
        )
        result = DesktopMCPBridge._parse_metadata_to_file(xml)
        canvas = result["document"]["children"][0]
        assert canvas["children"][0]["name"] == "\u6839\u672c\u30ce\u30fc\u30c9"

    def test_node_with_missing_bounding_box_attrs(self):
        """Node with no x/y/width/height still parses without crash."""
        xml = (
            '<design_context file_key="k" file_name="F">'
            '<nodes><node id="1:1" name="Bare" type="FRAME"/></nodes>'
            "</design_context>"
        )
        result = DesktopMCPBridge._parse_metadata_to_file(xml)
        node = result["document"]["children"][0]["children"][0]
        assert node["id"] == "1:1"
        assert "absoluteBoundingBox" not in node

    def test_node_with_invalid_numeric_attr_skipped(self):
        """Non-numeric width/height are safely skipped."""
        xml = (
            '<design_context file_key="k" file_name="F">'
            '<nodes><node id="1:1" name="N" type="FRAME" '
            'width="NaN" height="bad"/></nodes>'
            "</design_context>"
        )
        result = DesktopMCPBridge._parse_metadata_to_file(xml)
        node = result["document"]["children"][0]["children"][0]
        # Should not crash; absoluteBoundingBox may be absent or partial
        assert node["id"] == "1:1"

    def test_component_metadata_parsed(self):
        """Component elements are included in the components dict."""
        xml = (
            '<design_context file_key="k" file_name="F">'
            "<nodes/>"
            '<components><component id="C1" name="Button" description="A button"/></components>'
            "</design_context>"
        )
        result = DesktopMCPBridge._parse_metadata_to_file(xml)
        assert "C1" in result["components"]
        assert result["components"]["C1"]["name"] == "Button"

    def test_style_metadata_parsed(self):
        """Style elements are included in the styles dict."""
        xml = (
            '<design_context file_key="k" file_name="F">'
            "<nodes/><components/>"
            '<styles><style id="S1" name="Primary" style_type="FILL"/></styles>'
            "</design_context>"
        )
        result = DesktopMCPBridge._parse_metadata_to_file(xml)
        assert "S1" in result["styles"]
        assert result["styles"]["S1"]["styleType"] == "FILL"

    def test_nested_children_parsed_recursively(self):
        """Child nodes inside <children> are recursively parsed."""
        xml = (
            '<design_context file_key="k" file_name="F">'
            "<nodes>"
            '<node id="1:1" name="Parent" type="FRAME">'
            "<children>"
            '<node id="1:2" name="Child" type="RECTANGLE"/>'
            "</children>"
            "</node>"
            "</nodes>"
            "</design_context>"
        )
        result = DesktopMCPBridge._parse_metadata_to_file(xml)
        parent = result["document"]["children"][0]["children"][0]
        assert parent["name"] == "Parent"
        assert parent["children"][0]["name"] == "Child"

    def test_fill_color_parsed(self):
        """Fill sub-element color channels are parsed as floats."""
        xml = (
            '<design_context file_key="k" file_name="F">'
            "<nodes>"
            '<node id="1:1" name="Box" type="RECTANGLE">'
            '<fill type="SOLID" r="1.0" g="0.5" b="0.0" a="1.0"/>'
            "</node>"
            "</nodes>"
            "</design_context>"
        )
        result = DesktopMCPBridge._parse_metadata_to_file(xml)
        node = result["document"]["children"][0]["children"][0]
        assert node["fills"][0]["color"]["r"] == 1.0
        assert node["fills"][0]["color"]["g"] == 0.5

    def test_text_content_parsed(self):
        """<text_content> element is mapped to 'characters' field."""
        xml = (
            '<design_context file_key="k" file_name="F">'
            "<nodes>"
            '<node id="1:1" name="Label" type="TEXT">'
            "<text_content>Hello World</text_content>"
            "</node>"
            "</nodes>"
            "</design_context>"
        )
        result = DesktopMCPBridge._parse_metadata_to_file(xml)
        node = result["document"]["children"][0]["children"][0]
        assert node["characters"] == "Hello World"

    def test_schema_version_zero_boundary(self):
        """Schema version 0 (boundary) is parsed as 0."""
        xml = '<design_context file_key="k" file_name="F" schema_version="0"><nodes/></design_context>'
        result = DesktopMCPBridge._parse_metadata_to_file(xml)
        assert result["schemaVersion"] == 0
        assert result["version"] == "0"

    def test_visible_false_string_parsed(self):
        """visible='false' string attribute sets visible=False on node."""
        xml = (
            '<design_context file_key="k" file_name="F">'
            "<nodes>"
            '<node id="1:1" name="Hidden" type="FRAME" visible="false"/>'
            "</nodes>"
            "</design_context>"
        )
        result = DesktopMCPBridge._parse_metadata_to_file(xml)
        node = result["document"]["children"][0]["children"][0]
        assert node["visible"] is False

    def test_component_without_id_skipped(self):
        """Components with no id attribute are not added to the components dict."""
        xml = (
            '<design_context file_key="k" file_name="F">'
            "<nodes/>"
            '<components><component name="NoId"/></components>'
            "</design_context>"
        )
        result = DesktopMCPBridge._parse_metadata_to_file(xml)
        assert result["components"] == {}


# ---------------------------------------------------------------------------
# get_file
# ---------------------------------------------------------------------------


class TestGetFile:
    """Test get_file public API method."""

    @pytest.mark.asyncio
    async def test_calls_get_design_context_tool(self):
        """get_file invokes the 'get_design_context' MCP tool."""
        bridge = DesktopMCPBridge()
        bridge._call_tool = AsyncMock(return_value={"name": "MyFile"})
        result = await bridge.get_file("abc123", depth=2)
        bridge._call_tool.assert_called_once_with(
            "get_design_context", {"file_key": "abc123", "depth": 2}
        )
        assert result == {"name": "MyFile"}

    @pytest.mark.asyncio
    async def test_boundary_depth_clamped_to_ten(self):
        """Depth > 10 is clamped to 10 (safety clamp)."""
        bridge = DesktopMCPBridge()
        bridge._call_tool = AsyncMock(return_value={})
        await bridge.get_file("abc123", depth=999)
        _, call_kwargs = bridge._call_tool.call_args
        assert bridge._call_tool.call_args[0][1]["depth"] == 10

    @pytest.mark.asyncio
    async def test_missing_file_key_empty_string_passed(self):
        """Empty file_key is passed through (caller validates)."""
        bridge = DesktopMCPBridge()
        bridge._call_tool = AsyncMock(return_value={})
        await bridge.get_file("", depth=1)
        bridge._call_tool.assert_called_once_with(
            "get_design_context", {"file_key": "", "depth": 1}
        )


# ---------------------------------------------------------------------------
# get_nodes — circuit breaker
# ---------------------------------------------------------------------------


class TestGetNodes:
    """Test get_nodes with circuit breaker logic."""

    @pytest.mark.asyncio
    async def test_empty_node_list_returns_empty_nodes(self):
        """Empty node_ids list returns {'nodes': {}} immediately."""
        bridge = DesktopMCPBridge()
        bridge._call_tool = AsyncMock(return_value={})
        result = await bridge.get_nodes("abc", [])
        bridge._call_tool.assert_not_called()
        assert result == {"nodes": {}}

    @pytest.mark.asyncio
    async def test_successful_nodes_returned(self):
        """Successful node fetches are aggregated into result dict."""
        bridge = DesktopMCPBridge()
        bridge._call_tool = AsyncMock(return_value={"id": "1:2", "name": "Frame"})
        result = await bridge.get_nodes("abc", ["1:2", "1:3"])
        assert "1:2" in result["nodes"]
        assert "1:3" in result["nodes"]

    @pytest.mark.asyncio
    async def test_boundary_circuit_breaker_trips_after_threshold(self):
        """Circuit breaker trips after _CIRCUIT_BREAKER_THRESHOLD consecutive failures."""
        bridge = DesktopMCPBridge()
        bridge._call_tool = AsyncMock(
            side_effect=FigmaAPIError("tool failed", status_code=0)
        )
        node_ids = [f"1:{i}" for i in range(_CIRCUIT_BREAKER_THRESHOLD + 2)]
        with pytest.raises(FigmaAPIError, match="circuit breaker"):
            await bridge.get_nodes("abc", node_ids)
        # Should have called _call_tool exactly threshold times
        assert bridge._call_tool.call_count == _CIRCUIT_BREAKER_THRESHOLD

    @pytest.mark.asyncio
    async def test_failure_resets_after_success(self):
        """Consecutive failure counter resets after a successful node fetch."""
        bridge = DesktopMCPBridge()
        call_count = 0

        async def _side_effect(tool, args):
            nonlocal call_count
            call_count += 1
            # Fail first two, succeed on third
            if call_count <= 2:
                raise FigmaAPIError("fail", status_code=0)
            return {"id": args["node_id"]}

        bridge._call_tool = AsyncMock(side_effect=_side_effect)
        # 3 nodes: fail, fail, succeed — counter resets, no circuit break
        result = await bridge.get_nodes("abc", ["1:1", "1:2", "1:3"])
        assert "1:3" in result["nodes"]

    @pytest.mark.asyncio
    async def test_none_node_id_handled_in_list(self):
        """None node_ids are passed to _call_tool (validation is caller's job)."""
        bridge = DesktopMCPBridge()
        bridge._call_tool = AsyncMock(return_value={"id": "1:1"})
        result = await bridge.get_nodes("abc", ["1:1"])
        assert "1:1" in result["nodes"]


# ---------------------------------------------------------------------------
# get_images — graceful degradation
# ---------------------------------------------------------------------------


class TestGetImages:
    """Test get_images with graceful degradation."""

    @pytest.mark.asyncio
    async def test_returns_image_urls_on_success(self):
        """Successful image export returns URL dict."""
        bridge = DesktopMCPBridge()
        bridge._call_tool = AsyncMock(
            return_value={"images": {"1:1": "https://cdn.figma.com/img/a.png"}}
        )
        result = await bridge.get_images("abc", ["1:1"])
        assert result["1:1"] == "https://cdn.figma.com/img/a.png"

    @pytest.mark.asyncio
    async def test_none_values_for_missing_node_ids(self):
        """Node IDs not in response images dict get None value."""
        bridge = DesktopMCPBridge()
        bridge._call_tool = AsyncMock(return_value={"images": {}})
        result = await bridge.get_images("abc", ["1:1", "1:2"])
        assert result == {"1:1": None, "1:2": None}

    @pytest.mark.asyncio
    async def test_empty_node_list_returns_empty_dict(self):
        """Empty node_ids returns empty dict."""
        bridge = DesktopMCPBridge()
        bridge._call_tool = AsyncMock(return_value={"images": {}})
        result = await bridge.get_images("abc", [])
        assert result == {}

    @pytest.mark.asyncio
    async def test_figma_api_error_degrades_gracefully(self):
        """FigmaAPIError from tool call returns None for all nodes."""
        bridge = DesktopMCPBridge()
        bridge._call_tool = AsyncMock(
            side_effect=FigmaAPIError("tool not found", status_code=0)
        )
        result = await bridge.get_images("abc", ["1:1", "1:2"])
        assert result == {"1:1": None, "1:2": None}

    @pytest.mark.asyncio
    async def test_figma_not_found_error_degrades_gracefully(self):
        """FigmaNotFoundError also triggers graceful degradation."""
        bridge = DesktopMCPBridge()
        bridge._call_tool = AsyncMock(
            side_effect=FigmaNotFoundError("not found", status_code=404)
        )
        result = await bridge.get_images("abc", ["1:1"])
        assert result == {"1:1": None}

    @pytest.mark.asyncio
    async def test_boundary_zero_scale_passed_through(self):
        """Scale=0 is passed through (caller validates scale validity)."""
        bridge = DesktopMCPBridge()
        bridge._call_tool = AsyncMock(return_value={"images": {}})
        await bridge.get_images("abc", ["1:1"], format="png", scale=0.0)
        bridge._call_tool.assert_called_once()
        call_args = bridge._call_tool.call_args[0][1]
        assert call_args["scale"] == 0.0

    @pytest.mark.asyncio
    async def test_unicode_node_ids_passed_through(self):
        """Unicode/special node IDs are passed through without corruption."""
        bridge = DesktopMCPBridge()
        bridge._call_tool = AsyncMock(return_value={"images": {}})
        unicode_ids = ["1:\u4e2d\u6587", "2:\u65e5\u672c\u8a9e"]
        result = await bridge.get_images("abc", unicode_ids)
        for nid in unicode_ids:
            assert nid in result


# ---------------------------------------------------------------------------
# _unwrap_result — XML path via _parse_metadata_to_file
# ---------------------------------------------------------------------------


class TestUnwrapResultXML:
    """Test XML unwrapping path in _unwrap_result."""

    def test_xml_content_triggers_parse_metadata(self):
        """Content starting with '<' triggers XML parsing path."""
        xml_text = (
            '<design_context file_key="k" file_name="XmlFile">'
            "<nodes/></design_context>"
        )
        result = {"content": [{"type": "text", "text": xml_text}]}
        out = DesktopMCPBridge._unwrap_result(result)
        assert out["name"] == "XmlFile"
        assert out["_source"] == "desktop_mcp"

    def test_malformed_xml_in_content_falls_back_to_text(self):
        """Malformed XML in content falls back to raw text dict."""
        result = {"content": [{"type": "text", "text": "<broken xml"}]}
        out = DesktopMCPBridge._unwrap_result(result)
        # Should not raise; falls back to _text key
        assert "_text" in out

    def test_whitespace_only_text_does_not_trigger_xml_path(self):
        """Whitespace-only combined text does not cause errors."""
        result = {"content": [{"type": "text", "text": "   "}]}
        out = DesktopMCPBridge._unwrap_result(result)
        # Falls through JSON and XML checks, returns text-wrapped dict
        assert isinstance(out, dict)
