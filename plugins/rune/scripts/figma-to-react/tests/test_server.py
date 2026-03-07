"""Tests for server.py — MCP server tool wrappers and error handling."""
from __future__ import annotations

import json
import sys
from pathlib import Path
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

# Add parent directory to path so we can import the module under test
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from mcp.server.fastmcp import Context  # noqa: E402
from mcp.server.fastmcp.exceptions import ToolError  # noqa: E402

from figma_client import FigmaAPIError, FigmaAuthError, FigmaNotFoundError  # noqa: E402
from url_parser import FigmaURLError  # noqa: E402

# Import server module functions directly (not importing `mcp` object to avoid
# side effects of running the FastMCP server)
import server  # noqa: E402
from server import (  # noqa: E402
    _get_client,
    _handle_figma_error,
    figma_fetch_design,
    figma_inspect_node,
    figma_list_components,
    figma_to_react,
)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------


def _make_ctx(figma_client=None) -> MagicMock:
    """Build a mock MCP Context with optional FigmaClient."""
    ctx = MagicMock(spec=Context)
    lifespan_ctx = {"figma_client": figma_client if figma_client is not None else MagicMock()}
    ctx.request_context.lifespan_context = lifespan_ctx
    return ctx


def _make_client(
    file_data: dict | None = None,
    nodes_data: dict | None = None,
    react_data: dict | None = None,
    side_effect=None,
) -> MagicMock:
    """Build a mock FigmaClient for injection into context."""
    client = MagicMock()
    return client


# ---------------------------------------------------------------------------
# _get_client
# ---------------------------------------------------------------------------


class TestGetClient:
    """Test the _get_client helper."""

    def test_returns_client_from_context(self):
        """_get_client returns FigmaClient from request_context."""
        mock_client = MagicMock()
        ctx = _make_ctx(figma_client=mock_client)
        result = _get_client(ctx)
        assert result is mock_client

    def test_missing_figma_client_key_raises_tool_error(self):
        """Missing 'figma_client' key in lifespan_context raises ToolError."""
        ctx = MagicMock(spec=Context)
        ctx.request_context.lifespan_context = {}  # no figma_client key
        with pytest.raises(ToolError, match="FigmaClient not available"):
            _get_client(ctx)

    def test_none_lifespan_context_raises_tool_error(self):
        """None lifespan_context raises ToolError."""
        ctx = MagicMock(spec=Context)
        ctx.request_context.lifespan_context = None
        with pytest.raises(ToolError, match="FigmaClient not available"):
            _get_client(ctx)

    def test_non_subscriptable_lifespan_context_raises_tool_error(self):
        """Non-subscriptable lifespan_context raises ToolError."""
        ctx = MagicMock(spec=Context)
        # Set lifespan_context to a non-dict type — subscript will raise TypeError,
        # which _get_client wraps into ToolError via except (AttributeError, KeyError, TypeError)
        ctx.request_context.lifespan_context = "not-a-dict"
        with pytest.raises(ToolError, match="FigmaClient not available"):
            _get_client(ctx)


# ---------------------------------------------------------------------------
# _handle_figma_error
# ---------------------------------------------------------------------------


class TestHandleFigmaError:
    """Test FigmaAPIError -> ToolError conversion."""

    def test_converts_figma_api_error_to_tool_error(self):
        """FigmaAPIError message becomes ToolError message."""
        err = FigmaAPIError("file not accessible", status_code=403)
        tool_err = _handle_figma_error(err)
        assert isinstance(tool_err, ToolError)
        assert "file not accessible" in str(tool_err)

    def test_empty_message_converted(self):
        """Empty error message still produces ToolError."""
        err = FigmaAPIError("", status_code=0)
        tool_err = _handle_figma_error(err)
        assert isinstance(tool_err, ToolError)

    def test_unicode_message_preserved(self):
        """Unicode in error message is preserved in ToolError."""
        msg = "Erreur de l\u2019API Figma: \u6587\u4ef6\u672a\u627e\u5230"
        err = FigmaAPIError(msg, status_code=404)
        tool_err = _handle_figma_error(err)
        assert msg in str(tool_err)


# ---------------------------------------------------------------------------
# figma_fetch_design
# ---------------------------------------------------------------------------


class TestFigmaFetchDesign:
    """Test the figma_fetch_design tool wrapper."""

    @pytest.mark.asyncio
    async def test_successful_fetch_returns_json_string(self):
        """Successful core.fetch_design result is JSON-serialised."""
        expected = {"ir_tree": {"node_id": "1:1", "name": "Frame"}, "total_length": 100}
        ctx = _make_ctx()
        with patch("server.core.fetch_design", new_callable=AsyncMock, return_value=expected):
            result = await figma_fetch_design(
                url="https://www.figma.com/design/ABC/Title",
                ctx=ctx,
                depth=2,
                max_length=50000,
                start_index=0,
            )
        data = json.loads(result)
        assert data["ir_tree"]["name"] == "Frame"

    @pytest.mark.asyncio
    async def test_invalid_url_raises_tool_error(self):
        """FigmaURLError from core raises ToolError."""
        ctx = _make_ctx()
        with patch(
            "server.core.fetch_design",
            new_callable=AsyncMock,
            side_effect=FigmaURLError("not a figma URL"),
        ):
            with pytest.raises(ToolError, match="not a figma URL"):
                await figma_fetch_design(
                    url="https://not-figma.com/nope",
                    ctx=ctx,
                )

    @pytest.mark.asyncio
    async def test_empty_url_raises_tool_error(self):
        """Empty URL string triggers FigmaURLError -> ToolError."""
        ctx = _make_ctx()
        with patch(
            "server.core.fetch_design",
            new_callable=AsyncMock,
            side_effect=FigmaURLError("empty URL"),
        ):
            with pytest.raises(ToolError):
                await figma_fetch_design(url="", ctx=ctx)

    @pytest.mark.asyncio
    async def test_missing_token_api_error_raises_tool_error(self):
        """FigmaAPIError (e.g. no token) propagates as ToolError."""
        ctx = _make_ctx()
        with patch(
            "server.core.fetch_design",
            new_callable=AsyncMock,
            side_effect=FigmaAPIError("FIGMA_TOKEN not set", status_code=0),
        ):
            with pytest.raises(ToolError, match="FIGMA_TOKEN"):
                await figma_fetch_design(
                    url="https://www.figma.com/design/ABC/Title",
                    ctx=ctx,
                )

    @pytest.mark.asyncio
    async def test_boundary_depth_zero_passed_through(self):
        """depth=0 boundary value is passed to core without error."""
        ctx = _make_ctx()
        with patch(
            "server.core.fetch_design",
            new_callable=AsyncMock,
            return_value={"content": "{}"},
        ) as mock_fetch:
            await figma_fetch_design(
                url="https://www.figma.com/design/ABC/Title",
                ctx=ctx,
                depth=0,
            )
            mock_fetch.assert_called_once()
            assert mock_fetch.call_args[0][2] == 0  # depth is 3rd positional arg

    @pytest.mark.asyncio
    async def test_boundary_large_start_index(self):
        """Very large start_index is accepted without error."""
        ctx = _make_ctx()
        with patch(
            "server.core.fetch_design",
            new_callable=AsyncMock,
            return_value={"content": "end", "start_index": 999999},
        ):
            result = await figma_fetch_design(
                url="https://www.figma.com/design/ABC/Title",
                ctx=ctx,
                start_index=999999,
            )
        assert isinstance(result, str)

    @pytest.mark.asyncio
    async def test_malformed_request_context_raises_tool_error(self):
        """Context with no FigmaClient raises ToolError before calling core."""
        ctx = MagicMock(spec=Context)
        ctx.request_context.lifespan_context = {}  # missing figma_client
        with pytest.raises(ToolError, match="FigmaClient not available"):
            await figma_fetch_design(
                url="https://www.figma.com/design/ABC/Title",
                ctx=ctx,
            )

    @pytest.mark.asyncio
    async def test_none_response_from_core_serialises_to_null(self):
        """None result from core.fetch_design serialises to 'null' JSON."""
        ctx = _make_ctx()
        with patch(
            "server.core.fetch_design",
            new_callable=AsyncMock,
            return_value=None,
        ):
            result = await figma_fetch_design(
                url="https://www.figma.com/design/ABC/Title",
                ctx=ctx,
            )
        assert result == "null"


# ---------------------------------------------------------------------------
# figma_inspect_node
# ---------------------------------------------------------------------------


class TestFigmaInspectNode:
    """Test the figma_inspect_node tool wrapper."""

    @pytest.mark.asyncio
    async def test_successful_inspect_returns_json_string(self):
        """Successful core.inspect_node result is pretty-printed JSON."""
        expected = {"node_id": "1:3", "name": "Button", "node_type": "FRAME"}
        ctx = _make_ctx()
        with patch("server.core.inspect_node", new_callable=AsyncMock, return_value=expected):
            result = await figma_inspect_node(
                url="https://www.figma.com/design/ABC/Title?node-id=1-3",
                ctx=ctx,
            )
        data = json.loads(result)
        assert data["node_id"] == "1:3"

    @pytest.mark.asyncio
    async def test_missing_node_id_in_url_raises_tool_error(self):
        """URL without node-id raises ValueError -> ToolError."""
        ctx = _make_ctx()
        with patch(
            "server.core.inspect_node",
            new_callable=AsyncMock,
            side_effect=ValueError("node-id required"),
        ):
            with pytest.raises(ToolError, match="node-id"):
                await figma_inspect_node(
                    url="https://www.figma.com/design/ABC/Title",
                    ctx=ctx,
                )

    @pytest.mark.asyncio
    async def test_invalid_url_raises_tool_error(self):
        """Malformed URL raises FigmaURLError -> ToolError."""
        ctx = _make_ctx()
        with patch(
            "server.core.inspect_node",
            new_callable=AsyncMock,
            side_effect=FigmaURLError("cannot parse URL"),
        ):
            with pytest.raises(ToolError):
                await figma_inspect_node(url="not-a-url", ctx=ctx)

    @pytest.mark.asyncio
    async def test_figma_api_error_raises_tool_error(self):
        """FigmaAPIError from inspect_node raises ToolError."""
        ctx = _make_ctx()
        with patch(
            "server.core.inspect_node",
            new_callable=AsyncMock,
            side_effect=FigmaAPIError("rate limited", status_code=429),
        ):
            with pytest.raises(ToolError, match="rate limited"):
                await figma_inspect_node(
                    url="https://www.figma.com/design/ABC/Title?node-id=1-3",
                    ctx=ctx,
                )

    @pytest.mark.asyncio
    async def test_none_response_from_core_serialises(self):
        """None result from core.inspect_node serialises to 'null' JSON."""
        ctx = _make_ctx()
        with patch(
            "server.core.inspect_node",
            new_callable=AsyncMock,
            return_value=None,
        ):
            result = await figma_inspect_node(
                url="https://www.figma.com/design/ABC/Title?node-id=1-3",
                ctx=ctx,
            )
        assert result == "null"

    @pytest.mark.asyncio
    async def test_missing_token_raises_tool_error(self):
        """Missing FIGMA_TOKEN error from core propagates as ToolError."""
        ctx = _make_ctx()
        with patch(
            "server.core.inspect_node",
            new_callable=AsyncMock,
            side_effect=FigmaAuthError("FIGMA_TOKEN not set", status_code=0),
        ):
            with pytest.raises(ToolError):
                await figma_inspect_node(
                    url="https://www.figma.com/design/ABC/Title?node-id=1-3",
                    ctx=ctx,
                )


# ---------------------------------------------------------------------------
# figma_list_components
# ---------------------------------------------------------------------------


class TestFigmaListComponents:
    """Test the figma_list_components tool wrapper."""

    @pytest.mark.asyncio
    async def test_successful_list_returns_json_string(self):
        """Successful result is pretty-printed JSON."""
        expected = {"components": [], "duplicates": []}
        ctx = _make_ctx()
        with patch(
            "server.core.list_components", new_callable=AsyncMock, return_value=expected
        ):
            result = await figma_list_components(
                url="https://www.figma.com/design/ABC/Title",
                ctx=ctx,
            )
        data = json.loads(result)
        assert "components" in data

    @pytest.mark.asyncio
    async def test_invalid_url_raises_tool_error(self):
        """FigmaURLError raises ToolError."""
        ctx = _make_ctx()
        with patch(
            "server.core.list_components",
            new_callable=AsyncMock,
            side_effect=FigmaURLError("invalid URL"),
        ):
            with pytest.raises(ToolError):
                await figma_list_components(url="not-figma", ctx=ctx)

    @pytest.mark.asyncio
    async def test_empty_url_argument_raises_tool_error(self):
        """Empty string URL triggers URL parsing error -> ToolError."""
        ctx = _make_ctx()
        with patch(
            "server.core.list_components",
            new_callable=AsyncMock,
            side_effect=FigmaURLError("empty URL not valid"),
        ):
            with pytest.raises(ToolError):
                await figma_list_components(url="", ctx=ctx)

    @pytest.mark.asyncio
    async def test_figma_not_found_raises_tool_error(self):
        """FigmaNotFoundError from API propagates as ToolError."""
        ctx = _make_ctx()
        with patch(
            "server.core.list_components",
            new_callable=AsyncMock,
            side_effect=FigmaNotFoundError("file not found", status_code=404),
        ):
            with pytest.raises(ToolError, match="file not found"):
                await figma_list_components(
                    url="https://www.figma.com/design/MISSING/Title",
                    ctx=ctx,
                )

    @pytest.mark.asyncio
    async def test_missing_figma_client_raises_tool_error(self):
        """Missing FigmaClient in context raises ToolError before API call."""
        ctx = MagicMock(spec=Context)
        ctx.request_context.lifespan_context = {}
        with pytest.raises(ToolError, match="FigmaClient not available"):
            await figma_list_components(
                url="https://www.figma.com/design/ABC/Title",
                ctx=ctx,
            )

    @pytest.mark.asyncio
    async def test_boundary_empty_components_result(self):
        """Empty components result (zero items) serialises correctly."""
        ctx = _make_ctx()
        with patch(
            "server.core.list_components",
            new_callable=AsyncMock,
            return_value={"components": [], "total": 0},
        ):
            result = await figma_list_components(
                url="https://www.figma.com/design/ABC/Title",
                ctx=ctx,
            )
        data = json.loads(result)
        assert data["total"] == 0


# ---------------------------------------------------------------------------
# figma_to_react
# ---------------------------------------------------------------------------


class TestFigmaToReact:
    """Test the figma_to_react tool wrapper."""

    @pytest.mark.asyncio
    async def test_successful_conversion_returns_json_string(self):
        """Successful to_react result is JSON-serialised."""
        expected = {"main_component": "export default function MyComp() {}", "file_key": "ABC"}
        ctx = _make_ctx()
        with patch("server.core.to_react", new_callable=AsyncMock, return_value=expected):
            result = await figma_to_react(
                url="https://www.figma.com/design/ABC/Title?node-id=1-2",
                ctx=ctx,
            )
        data = json.loads(result)
        assert "main_component" in data

    @pytest.mark.asyncio
    async def test_invalid_url_raises_tool_error(self):
        """FigmaURLError from to_react raises ToolError."""
        ctx = _make_ctx()
        with patch(
            "server.core.to_react",
            new_callable=AsyncMock,
            side_effect=FigmaURLError("bad figma URL"),
        ):
            with pytest.raises(ToolError):
                await figma_to_react(url="https://not-figma.com/x", ctx=ctx)

    @pytest.mark.asyncio
    async def test_missing_token_error_raises_tool_error(self):
        """No FIGMA_TOKEN error propagates as ToolError."""
        ctx = _make_ctx()
        with patch(
            "server.core.to_react",
            new_callable=AsyncMock,
            side_effect=FigmaAPIError("FIGMA_TOKEN not set", status_code=0),
        ):
            with pytest.raises(ToolError, match="FIGMA_TOKEN"):
                await figma_to_react(
                    url="https://www.figma.com/design/ABC/Title?node-id=1-2",
                    ctx=ctx,
                )

    @pytest.mark.asyncio
    async def test_empty_component_name_uses_auto_detection(self):
        """Empty component_name string is passed through (auto-detect in core)."""
        ctx = _make_ctx()
        with patch(
            "server.core.to_react",
            new_callable=AsyncMock,
            return_value={"main_component": "export default function AutoName() {}"},
        ) as mock_to_react:
            await figma_to_react(
                url="https://www.figma.com/design/ABC/Title?node-id=1-2",
                ctx=ctx,
                component_name="",
            )
            call_kwargs = mock_to_react.call_args[1]
            assert call_kwargs["component_name"] == ""

    @pytest.mark.asyncio
    async def test_boundary_depth_max_length_zero(self):
        """max_length=0 boundary is passed through to core."""
        ctx = _make_ctx()
        with patch(
            "server.core.to_react",
            new_callable=AsyncMock,
            return_value={"content": ""},
        ) as mock_to_react:
            await figma_to_react(
                url="https://www.figma.com/design/ABC/Title?node-id=1-2",
                ctx=ctx,
                max_length=0,
            )
            call_kwargs = mock_to_react.call_args[1]
            assert call_kwargs["max_length"] == 0

    @pytest.mark.asyncio
    async def test_none_response_from_core_serialises(self):
        """None result from core.to_react serialises to 'null'."""
        ctx = _make_ctx()
        with patch(
            "server.core.to_react",
            new_callable=AsyncMock,
            return_value=None,
        ):
            result = await figma_to_react(
                url="https://www.figma.com/design/ABC/Title?node-id=1-2",
                ctx=ctx,
            )
        assert result == "null"

    @pytest.mark.asyncio
    async def test_malformed_request_no_client_raises_tool_error(self):
        """No FigmaClient in context raises ToolError before calling core."""
        ctx = MagicMock(spec=Context)
        ctx.request_context.lifespan_context = {}
        with pytest.raises(ToolError, match="FigmaClient not available"):
            await figma_to_react(
                url="https://www.figma.com/design/ABC/Title?node-id=1-2",
                ctx=ctx,
            )

    @pytest.mark.asyncio
    async def test_figma_api_error_propagates_as_tool_error(self):
        """Generic FigmaAPIError propagates as ToolError."""
        ctx = _make_ctx()
        with patch(
            "server.core.to_react",
            new_callable=AsyncMock,
            side_effect=FigmaAPIError("server error", status_code=500),
        ):
            with pytest.raises(ToolError, match="server error"):
                await figma_to_react(
                    url="https://www.figma.com/design/ABC/Title?node-id=1-2",
                    ctx=ctx,
                )

    @pytest.mark.asyncio
    async def test_unicode_component_name_passed_through(self):
        """Unicode component_name is accepted and passed to core."""
        ctx = _make_ctx()
        with patch(
            "server.core.to_react",
            new_callable=AsyncMock,
            return_value={"main_component": "// ok"},
        ) as mock_to_react:
            await figma_to_react(
                url="https://www.figma.com/design/ABC/Title?node-id=1-2",
                ctx=ctx,
                component_name="\u30b3\u30f3\u30dd\u30fc\u30cd\u30f3\u30c8",
            )
            call_kwargs = mock_to_react.call_args[1]
            assert call_kwargs["component_name"] == "\u30b3\u30f3\u30dd\u30fc\u30cd\u30f3\u30c8"

    @pytest.mark.asyncio
    async def test_boundary_negative_start_index_passed_through(self):
        """Negative start_index is passed to core (validation is core's job)."""
        ctx = _make_ctx()
        with patch(
            "server.core.to_react",
            new_callable=AsyncMock,
            return_value={"content": "x"},
        ) as mock_to_react:
            await figma_to_react(
                url="https://www.figma.com/design/ABC/Title?node-id=1-2",
                ctx=ctx,
                start_index=-1,
            )
            call_kwargs = mock_to_react.call_args[1]
            assert call_kwargs["start_index"] == -1

    @pytest.mark.asyncio
    async def test_extract_components_and_aria_flags_passed_through(self):
        """extract_components=True and aria=True are forwarded to core."""
        ctx = _make_ctx()
        with patch(
            "server.core.to_react",
            new_callable=AsyncMock,
            return_value={"main_component": "// ok"},
        ) as mock_to_react:
            await figma_to_react(
                url="https://www.figma.com/design/ABC/Title?node-id=1-2",
                ctx=ctx,
                extract_components=True,
                aria=True,
            )
            call_kwargs = mock_to_react.call_args[1]
            assert call_kwargs["extract_components"] is True
            assert call_kwargs["aria"] is True


# ---------------------------------------------------------------------------
# Server module structure
# ---------------------------------------------------------------------------


class TestServerModuleStructure:
    """Validate server module structure and constants."""

    def test_mcp_instance_exists(self):
        """The 'mcp' FastMCP instance is defined in server module."""
        assert hasattr(server, "mcp")

    def test_tool_functions_are_callable(self):
        """All four tool functions are callable."""
        import asyncio
        assert callable(figma_fetch_design)
        assert callable(figma_inspect_node)
        assert callable(figma_list_components)
        assert callable(figma_to_react)

    def test_get_client_helper_is_callable(self):
        """_get_client helper is accessible and callable."""
        assert callable(_get_client)

    def test_handle_figma_error_helper_is_callable(self):
        """_handle_figma_error helper is accessible and callable."""
        assert callable(_handle_figma_error)

    def test_default_constants_from_core_used(self):
        """server.py references core.DEFAULT_MAX_LENGTH and core.DEFAULT_START_INDEX."""
        import core
        # Verify these constants exist (they are used as default arg values)
        assert hasattr(core, "DEFAULT_MAX_LENGTH")
        assert hasattr(core, "DEFAULT_START_INDEX")
        assert core.DEFAULT_MAX_LENGTH == 50000
        assert core.DEFAULT_START_INDEX == 0
