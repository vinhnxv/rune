"""
Figma Desktop MCP Bridge

Bridges the Figma Desktop MCP server running locally at http://127.0.0.1:3845/mcp.
Uses JSON-RPC 2.0 over HTTP to invoke MCP tools exposed by the desktop app.

Reuses exception hierarchy from figma_client.py — no new exceptions are introduced.

Security:
  - Only connects to localhost (127.0.0.1), never to external hosts.
  - Does not require or log authentication tokens.

Usage::

    bridge = DesktopMCPBridge()
    if await bridge.is_available():
        file_data = await bridge.get_file("abc123", depth=2)
    await bridge.close()
"""

from __future__ import annotations

import logging
import xml.etree.ElementTree as ET
from typing import Any, Optional

try:
    import defusedxml.ElementTree as SafeET
except ImportError:
    SafeET = ET  # type: ignore[misc]  # Fallback to stdlib if defusedxml not installed
    logging.getLogger(__name__).warning(
        "defusedxml not installed — XML parsing lacks XXE protection. "
        "Install with: pip install defusedxml>=0.7.1"
    )

import httpx

from figma_client import (
    FigmaAPIError,
    FigmaNotFoundError,
    _DEFAULT_TIMEOUT,
)

logger = logging.getLogger(__name__)

# Maximum number of consecutive node fetch failures before aborting the loop.
_CIRCUIT_BREAKER_THRESHOLD = 3


# ---------------------------------------------------------------------------
# Module-level XML parsing helpers (used by _parse_metadata_to_file)
# ---------------------------------------------------------------------------


def _parse_fill(elem: ET.Element) -> dict[str, Any]:
    """Parse a <fill> XML element into a Figma fill dict."""
    fill_type = elem.get("type", "SOLID")
    color = {
        "r": float(elem.get("r", 0)),
        "g": float(elem.get("g", 0)),
        "b": float(elem.get("b", 0)),
        "a": float(elem.get("a", 1)),
    }
    return {"type": fill_type, "color": color}


def _parse_stroke(elem: ET.Element) -> dict[str, Any]:
    """Parse a <stroke> XML element into a Figma stroke dict."""
    stroke_type = elem.get("type", "SOLID")
    color = {
        "r": float(elem.get("r", 0)),
        "g": float(elem.get("g", 0)),
        "b": float(elem.get("b", 0)),
        "a": float(elem.get("a", 1)),
    }
    return {
        "type": stroke_type,
        "color": color,
        "strokeWeight": float(elem.get("weight", 1)),
    }


def _parse_node_bbox(node_elem: ET.Element, node: dict[str, Any]) -> None:
    """Populate absoluteBoundingBox on node dict from XML attributes."""
    for attr in ("x", "y", "width", "height"):
        val = node_elem.get(attr)
        if val is not None:
            try:
                node.setdefault("absoluteBoundingBox", {})[
                    {"x": "x", "y": "y", "width": "width", "height": "height"}[attr]
                ] = float(val)
            except (ValueError, TypeError):
                pass


def _parse_node_scalar_attrs(node_elem: ET.Element, node: dict[str, Any]) -> None:
    """Populate opacity and visible fields from XML attributes."""
    opacity = node_elem.get("opacity")
    if opacity is not None:
        try:
            node["opacity"] = float(opacity)
        except (ValueError, TypeError):
            pass

    visible = node_elem.get("visible")
    if visible is not None:
        node["visible"] = visible.lower() != "false"


def _parse_node_styles(node_elem: ET.Element, node: dict[str, Any]) -> None:
    """Populate fills, strokes, and text content from XML child elements."""
    fills = [_parse_fill(f) for f in node_elem.findall("fill")]
    if fills:
        node["fills"] = fills

    strokes = [_parse_stroke(s) for s in node_elem.findall("stroke")]
    if strokes:
        node["strokes"] = strokes

    text_elem = node_elem.find("text_content")
    if text_elem is not None and text_elem.text:
        node["characters"] = text_elem.text


def _parse_xml_node(node_elem: ET.Element) -> dict[str, Any]:
    """Recursively parse a <node> element into a Figma-API-compatible dict."""
    node: dict[str, Any] = {
        "id": node_elem.get("id", ""),
        "name": node_elem.get("name", ""),
        "type": node_elem.get("type", "FRAME"),
    }

    _parse_node_bbox(node_elem, node)
    _parse_node_scalar_attrs(node_elem, node)
    _parse_node_styles(node_elem, node)

    children_elem = node_elem.find("children")
    if children_elem is not None:
        node["children"] = [_parse_xml_node(child) for child in children_elem]

    return node


def _parse_xml_components(root: ET.Element) -> dict[str, dict[str, Any]]:
    """Parse <components> section of design context XML."""
    components: dict[str, dict[str, Any]] = {}
    comps_elem = root.find("components")
    if comps_elem is not None:
        for comp in comps_elem:
            comp_id = comp.get("id", "")
            if comp_id:
                components[comp_id] = {
                    "key": comp_id,
                    "name": comp.get("name", ""),
                    "description": comp.get("description", ""),
                }
    return components


def _parse_xml_styles(root: ET.Element) -> dict[str, dict[str, Any]]:
    """Parse <styles> section of design context XML."""
    styles: dict[str, dict[str, Any]] = {}
    styles_elem = root.find("styles")
    if styles_elem is not None:
        for style in styles_elem:
            style_id = style.get("id", "")
            if style_id:
                styles[style_id] = {
                    "key": style_id,
                    "name": style.get("name", ""),
                    "styleType": style.get("style_type", ""),
                    "description": style.get("description", ""),
                }
    return styles


def _build_file_envelope(
    file_key: str,
    file_name: str,
    schema_version: int,
    parsed_nodes: list[dict[str, Any]],
    components: dict[str, dict[str, Any]],
    styles: dict[str, dict[str, Any]],
) -> dict[str, Any]:
    """Assemble a Figma REST-API-compatible file envelope."""
    document: dict[str, Any] = {
        "id": "0:0",
        "name": "Document",
        "type": "DOCUMENT",
        "children": [
            {
                "id": "0:1",
                "name": file_name,
                "type": "CANVAS",
                "children": parsed_nodes,
            }
        ],
    }
    return {
        "name": file_name,
        "role": "viewer",
        "lastModified": "",
        "editorType": "figma",
        "thumbnailUrl": "",
        "version": str(schema_version),
        "document": document,
        "components": components,
        "componentSets": {},
        "schemaVersion": schema_version,
        "styles": styles,
        "mainFileKey": file_key,
        # Marker so downstream code can detect Desktop MCP responses.
        "_source": "desktop_mcp",
    }


class DesktopMCPBridge:
    """Bridge to Figma Desktop MCP server (127.0.0.1:3845).

    The Figma Desktop app exposes an MCP-compatible HTTP endpoint on a fixed
    loopback port. This bridge translates Figma API calls into JSON-RPC tool
    invocations, allowing the rest of the system to use the Desktop app as a
    backend without a Figma Personal Access Token.

    Availability is checked with ``is_available()`` before routing requests.
    If the Desktop app is not running, is_available() returns False and the
    caller should fall back to the REST API client.

    Usage::

        bridge = DesktopMCPBridge()
        if await bridge.is_available():
            data = await bridge.get_file("abc123")
        await bridge.close()
    """

    DESKTOP_URL = "http://127.0.0.1:3845/mcp"

    def __init__(self, *, timeout: float = _DEFAULT_TIMEOUT) -> None:
        """Initialise the bridge.

        Args:
            timeout: HTTP request timeout in seconds (default matches REST client).
        """
        self._timeout = timeout
        self._client: Optional[httpx.AsyncClient] = None
        self._rpc_id = 0

    # ------------------------------------------------------------------
    # Lifecycle
    # ------------------------------------------------------------------

    async def _ensure_client(self) -> httpx.AsyncClient:
        """Lazily create the shared httpx client."""
        if self._client is None or self._client.is_closed:
            self._client = httpx.AsyncClient(
                timeout=self._timeout,
            )
        return self._client

    async def close(self) -> None:
        """Close the underlying HTTP client."""
        if self._client is not None and not self._client.is_closed:
            await self._client.aclose()

    async def __aenter__(self) -> DesktopMCPBridge:
        """Enter the async context manager."""
        return self

    async def __aexit__(self, *exc: object) -> None:
        """Exit the async context manager and close the client."""
        await self.close()

    # ------------------------------------------------------------------
    # JSON-RPC helpers
    # ------------------------------------------------------------------

    def _next_id(self) -> int:
        """Return a monotonically increasing request ID."""
        self._rpc_id += 1
        return self._rpc_id

    def _build_rpc_payload(self, method: str, params: dict[str, Any]) -> dict[str, Any]:
        """Build a JSON-RPC 2.0 request payload."""
        return {
            "jsonrpc": "2.0",
            "id": self._next_id(),
            "method": method,
            "params": params,
        }

    async def _probe_desktop_mcp(self, client: httpx.AsyncClient) -> bool:
        """POST a tools/list probe and return True if the server responds ok."""
        payload = self._build_rpc_payload("tools/list", {})
        response = await client.post(
            self.DESKTOP_URL,
            json=payload,
            headers={"Content-Type": "application/json"},
        )
        if response.status_code != 200:
            logger.debug(
                "Desktop MCP probe returned HTTP %d — server unavailable.",
                response.status_code,
            )
            return False
        body = response.json()
        if "error" in body:
            logger.debug(
                "Desktop MCP tools/list returned RPC error: %s",
                body["error"],
            )
            return False
        logger.debug("Figma Desktop MCP server is available.")
        return True

    async def is_available(self) -> bool:
        """Probe the Desktop MCP server with a ``tools/list`` call.

        Uses ``tools/list`` rather than ``initialize`` because the latter
        requires a pre-negotiated ``Mcp-Session-Id`` header that is only
        established after a full MCP handshake.

        Returns:
            True if the server responded successfully, False otherwise.
        """
        try:
            client = await self._ensure_client()
            return await self._probe_desktop_mcp(client)
        except (httpx.ConnectError, httpx.TimeoutException, OSError) as exc:
            logger.debug("Figma Desktop MCP server not reachable: %s", exc)
            return False
        except (ValueError, RuntimeError, TypeError, AttributeError) as exc:
            logger.debug("Unexpected error probing Desktop MCP: %s", exc)
            return False

    async def _post_rpc(
        self, client: httpx.AsyncClient, payload: dict[str, Any], tool_name: str
    ) -> httpx.Response:
        """POST a JSON-RPC payload, mapping transport errors to FigmaAPIError."""
        try:
            return await client.post(
                self.DESKTOP_URL,
                json=payload,
                headers={"Content-Type": "application/json"},
            )
        except httpx.TimeoutException as exc:
            raise FigmaAPIError(
                f"Desktop MCP request timed out after {self._timeout}s "
                f"(tool={tool_name})",
                status_code=0,
            ) from exc
        except httpx.HTTPError as exc:
            raise FigmaAPIError(
                f"Desktop MCP connection error: {exc}",
                status_code=0,
            ) from exc

    @staticmethod
    def _check_rpc_error(body: dict[str, Any], tool_name: str) -> None:
        """Raise a typed exception if the JSON-RPC body contains an error."""
        if "error" not in body:
            return
        rpc_err = body["error"]
        code = rpc_err.get("code", 0)
        message = rpc_err.get("message", "Unknown RPC error")
        if code == -32600 or "not found" in message.lower():
            raise FigmaNotFoundError(
                f"Desktop MCP tool '{tool_name}' not found or file not found: {message}",
                status_code=404,
            )
        raise FigmaAPIError(
            f"Desktop MCP RPC error (code={code}): {message}",
            status_code=0,
        )

    async def _call_tool(self, tool_name: str, arguments: dict[str, Any]) -> dict[str, Any]:
        """Invoke an MCP tool via JSON-RPC and return its result.

        Args:
            tool_name: Name of the MCP tool to call.
            arguments: Tool arguments dict.

        Returns:
            The ``result`` field from the JSON-RPC response.

        Raises:
            FigmaAPIError: On HTTP errors, JSON-RPC errors, or timeout.
        """
        client = await self._ensure_client()
        payload = self._build_rpc_payload(
            "tools/call",
            {"name": tool_name, "arguments": arguments},
        )

        response = await self._post_rpc(client, payload, tool_name)

        if response.status_code != 200:
            raise FigmaAPIError(
                f"Desktop MCP returned HTTP {response.status_code} "
                f"(tool={tool_name}). "
                "Check that the Figma Desktop app is running.",
                status_code=response.status_code,
            )

        body = response.json()
        self._check_rpc_error(body, tool_name)

        result = body.get("result", {})
        # MCP tool results are often wrapped in a content list; unwrap if needed.
        return self._unwrap_result(result)

    # ------------------------------------------------------------------
    # Result parsing
    # ------------------------------------------------------------------

    @staticmethod
    def _extract_text_from_content(content: list[Any]) -> list[str]:
        """Extract all text strings from an MCP content list."""
        texts: list[str] = []
        for item in content:
            if isinstance(item, dict) and item.get("type") == "text":
                texts.append(item.get("text", ""))
        return texts

    @staticmethod
    def _parse_combined_text(combined: str, original: dict[str, Any]) -> dict[str, Any]:
        """Parse a combined text string as JSON or XML, falling back to raw text."""
        import json  # noqa: PLC0415 (lazy import — only needed here)
        try:
            parsed = json.loads(combined)
            if isinstance(parsed, dict):
                return parsed
            return {"data": parsed}
        except (json.JSONDecodeError, ValueError):
            pass

        if combined.strip().startswith("<"):
            try:
                return DesktopMCPBridge._parse_metadata_to_file(combined)
            except ET.ParseError:
                logger.debug("Desktop MCP result: XML parse failed, returning raw text.")

        return {"_text": combined, **original}

    @staticmethod
    def _unwrap_result(result: Any) -> dict[str, Any]:
        """Normalise MCP tool result into a plain dict.

        MCP tools return results in a ``content`` list where each item has
        a ``type`` and ``text`` field. When the text is JSON it is parsed;
        when it is XML (Figma design context) it is converted to a dict.

        Args:
            result: Raw JSON-RPC result value.

        Returns:
            Normalised dict, or the original value if no unwrapping needed.
        """
        if not isinstance(result, dict):
            return {"_raw": result}

        content = result.get("content")
        if not content or not isinstance(content, list):
            return result

        texts = DesktopMCPBridge._extract_text_from_content(content)
        if not texts:
            return result

        combined = "\n".join(texts)
        return DesktopMCPBridge._parse_combined_text(combined, result)

    @staticmethod
    def _parse_metadata_to_file(xml_text: str) -> dict[str, Any]:
        """Convert Figma Desktop XML to a Figma-REST-API-compatible dict.

        Parses the ``<design_context>`` XML emitted by the Desktop MCP into a
        structure close enough to ``/v1/files/{key}`` so downstream parsers
        can treat both backends uniformly.

        Args:
            xml_text: Raw XML string from the Desktop MCP response.

        Returns:
            Dict shaped like a Figma REST API file response.

        Raises:
            ET.ParseError: If the XML is malformed (caller handles this).
        """
        if len(xml_text) > 10_000_000:
            raise ValueError("XML response too large (>10MB)")
        root = SafeET.fromstring(xml_text)

        file_key = root.get("file_key", "")
        file_name = root.get("file_name", "unknown")
        schema_version = int(root.get("schema_version", "0"))

        nodes_elem = root.find("nodes")
        parsed_nodes: list[dict[str, Any]] = []
        if nodes_elem is not None:
            parsed_nodes = [_parse_xml_node(n) for n in nodes_elem]

        components = _parse_xml_components(root)
        styles = _parse_xml_styles(root)

        return _build_file_envelope(
            file_key, file_name, schema_version, parsed_nodes, components, styles
        )

    # ------------------------------------------------------------------
    # Public API — mirrors FigmaClient interface
    # ------------------------------------------------------------------

    async def get_file(
        self,
        file_key: str,
        *,
        depth: int = 2,
    ) -> dict[str, Any]:
        """Fetch a Figma file's design context via the Desktop MCP.

        Calls the ``get_design_context`` tool exposed by the Desktop app.

        Args:
            file_key: The Figma file key (from the file URL).
            depth: Traversal depth hint (passed to the tool when supported).

        Returns:
            File data shaped like the Figma REST API response.

        Raises:
            FigmaAPIError: On tool invocation failure.
        """
        logger.debug("Desktop bridge: get_file(%s, depth=%d)", file_key, depth)
        depth = min(depth, 10)  # Safety clamp consistent with REST client.
        return await self._call_tool(
            "get_design_context",
            {"file_key": file_key, "depth": depth},
        )

    async def _fetch_single_node(
        self,
        file_key: str,
        node_id: str,
        results: dict[str, Any],
        consecutive_failures: int,
    ) -> int:
        """Fetch one node and return updated consecutive_failures count.

        Returns 0 on success (counter reset); raises FigmaAPIError when the
        circuit-breaker threshold is reached.
        """
        try:
            node_data = await self._call_tool(
                "get_node_details",
                {"file_key": file_key, "node_id": node_id},
            )
            results["nodes"][node_id] = {"document": node_data}
            return 0  # Reset on success.
        except FigmaAPIError as exc:
            consecutive_failures += 1
            logger.warning(
                "Desktop bridge: get_node_details failed for node %s "
                "(consecutive_failures=%d): %s",
                node_id,
                consecutive_failures,
                exc,
            )
            if consecutive_failures >= _CIRCUIT_BREAKER_THRESHOLD:
                raise FigmaAPIError(
                    f"Desktop MCP circuit breaker tripped after "
                    f"{_CIRCUIT_BREAKER_THRESHOLD} consecutive failures "
                    f"fetching nodes from file '{file_key}'. "
                    "Last error: " + str(exc),
                    status_code=0,
                ) from exc
            return consecutive_failures

    async def get_nodes(
        self,
        file_key: str,
        node_ids: list[str],
    ) -> dict[str, Any]:
        """Fetch specific nodes from a Figma file via the Desktop MCP.

        Calls ``get_node_details`` for each node ID individually (the Desktop
        MCP typically does not support batched node fetching). A circuit breaker
        aborts after ``_CIRCUIT_BREAKER_THRESHOLD`` consecutive failures to
        prevent runaway calls when the server is degraded.

        Args:
            file_key: The Figma file key.
            node_ids: List of node IDs in colon format (e.g., ["1:3", "4:5"]).

        Returns:
            Dict keyed by node ID mapping to node data, shaped like
            ``/v1/files/{key}/nodes`` response.

        Raises:
            FigmaAPIError: If the circuit breaker trips (3 consecutive failures).
        """
        logger.debug(
            "Desktop bridge: get_nodes(%s, %d nodes)", file_key, len(node_ids)
        )
        results: dict[str, Any] = {"nodes": {}}
        consecutive_failures = 0

        for node_id in node_ids:
            consecutive_failures = await self._fetch_single_node(
                file_key, node_id, results, consecutive_failures
            )

        return results

    async def _build_image_result(
        self,
        file_key: str,
        node_ids: list[str],
        format: str,
        scale: float,
    ) -> dict[str, Optional[str]]:
        """Invoke the export_node_images tool and return a complete result dict."""
        result = await self._call_tool(
            "export_node_images",
            {
                "file_key": file_key,
                "node_ids": node_ids,
                "format": format,
                "scale": scale,
            },
        )
        images = result.get("images", {})
        return {nid: images.get(nid) for nid in node_ids}

    async def get_images(
        self,
        file_key: str,
        node_ids: list[str],
        *,
        format: str = "png",
        scale: float = 2.0,
    ) -> dict[str, Optional[str]]:
        """Attempt to export node images via the Desktop MCP.

        Image export is not guaranteed to be available through the Desktop MCP.
        When the tool is not found or returns an error, this method degrades
        gracefully by returning a dict with None values for each requested node.

        Args:
            file_key: The Figma file key.
            node_ids: List of node IDs to export.
            format: Image format ("png", "svg", "jpg").
            scale: Export scale factor.

        Returns:
            Dict mapping node_id to image URL string, or None if unavailable.
        """
        logger.debug(
            "Desktop bridge: get_images(%s, %d nodes, format=%s)",
            file_key,
            len(node_ids),
            format,
        )
        try:
            return await self._build_image_result(file_key, node_ids, format, scale)
        except (FigmaAPIError, FigmaNotFoundError) as exc:
            logger.info(
                "Desktop MCP image export not available (graceful degradation): %s",
                exc,
            )
            return {nid: None for nid in node_ids}
