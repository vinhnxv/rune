"""
Figma REST API Client

Async HTTP client for the Figma REST API with two-tier response caching,
rate-limit awareness, and depth-limited fetching.

Environment variables:
  FIGMA_TOKEN            - Personal access token (required for API calls)
  FIGMA_FILE_CACHE_TTL   - Cache TTL for file/node data in seconds (default: 1800)
  FIGMA_IMAGE_CACHE_TTL  - Cache TTL for image export URLs in seconds (default: 86400)

Security:
  - Token is NEVER logged or included in error messages.
  - All requests go to api.figma.com over HTTPS only.

Rate limits:
  Figma View/Collab seats are limited to approximately 6 requests/month on
  some plans. If you hit 429 errors with X-Figma-Plan-Tier, you may need
  a higher-tier plan or to reduce request frequency significantly.
"""

from __future__ import annotations

import logging
import os
import time
from dataclasses import dataclass, field
from typing import Any, Optional

import httpx

logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

_BASE_URL = "https://api.figma.com"
def _int_env(name: str, default: int) -> int:
    """Parse an integer environment variable with safe fallback."""
    raw = os.environ.get(name)
    if raw is None:
        return default
    try:
        return int(raw)
    except (ValueError, TypeError):
        logger.warning("Invalid integer for %s=%r, using default %d", name, raw, default)
        return default

_DEFAULT_FILE_CACHE_TTL = _int_env("FIGMA_FILE_CACHE_TTL", 1800)
_DEFAULT_IMAGE_CACHE_TTL = _int_env("FIGMA_IMAGE_CACHE_TTL", 86400)
_DEFAULT_TIMEOUT = 30.0  # seconds


# ---------------------------------------------------------------------------
# Exceptions
# ---------------------------------------------------------------------------


class FigmaAPIError(Exception):
    """Base exception for Figma API errors."""

    def __init__(self, message: str, status_code: int = 0) -> None:
        super().__init__(message)
        self.status_code = status_code


class FigmaAuthError(FigmaAPIError):
    """Raised on 403 — token is invalid or lacks access."""


class FigmaNotFoundError(FigmaAPIError):
    """Raised on 404 — file or node does not exist."""


class FigmaRateLimitError(FigmaAPIError):
    """Raised on 429 — rate limit exceeded.

    Attributes:
        retry_after: Seconds to wait before retrying (from Retry-After header).
        rate_limit_type: The X-Figma-Rate-Limit-Type header value, if present.
        plan_tier: The X-Figma-Plan-Tier header value, if present.
    """

    def __init__(
        self,
        message: str,
        retry_after: Optional[float] = None,
        rate_limit_type: Optional[str] = None,
        plan_tier: Optional[str] = None,
    ) -> None:
        super().__init__(message, status_code=429)
        self.retry_after = retry_after
        self.rate_limit_type = rate_limit_type
        self.plan_tier = plan_tier


class FigmaBadRequestError(FigmaAPIError):
    """Raised on 400 — malformed request (invalid node IDs, etc.)."""


# ---------------------------------------------------------------------------
# Cache
# ---------------------------------------------------------------------------


@dataclass
class _CacheEntry:
    """A single cached response with expiry time."""

    data: Any
    expires_at: float


_DEFAULT_MAX_CACHE_ENTRIES = 256  # BACK-P3-007: Prevent unbounded growth


@dataclass
class ResponseCache:
    """Two-tier in-memory cache for Figma API responses.

    Separates file/node data (shorter TTL) from image export URLs
    (longer TTL) because image URLs are expensive to generate and
    remain valid for extended periods.

    Bounded to ``max_entries`` to prevent unbounded memory growth in
    long-running MCP server processes.
    """

    file_ttl: int = _DEFAULT_FILE_CACHE_TTL
    image_ttl: int = _DEFAULT_IMAGE_CACHE_TTL
    max_entries: int = _DEFAULT_MAX_CACHE_ENTRIES
    _store: dict[str, _CacheEntry] = field(default_factory=dict)

    def get(self, key: str) -> Optional[Any]:
        """Retrieve a cached value if it exists and has not expired.

        Args:
            key: The cache key.

        Returns:
            The cached data, or None if expired or missing.
        """
        entry = self._store.get(key)
        if entry is None:
            return None
        if time.monotonic() > entry.expires_at:
            del self._store[key]
            return None
        return entry.data

    def set(self, key: str, data: Any, *, is_image: bool = False) -> None:
        """Store a value in the cache.

        Evicts the oldest entry when the cache exceeds ``max_entries``.

        Args:
            key: The cache key.
            data: The data to cache.
            is_image: If True, uses the longer image TTL.
        """
        # Evict soonest-to-expire entry if at capacity (BACK-P3-007)
        if len(self._store) >= self.max_entries and key not in self._store:
            expiring_key = min(self._store, key=lambda k: self._store[k].expires_at)
            del self._store[expiring_key]
        ttl = self.image_ttl if is_image else self.file_ttl
        self._store[key] = _CacheEntry(
            data=data,
            expires_at=time.monotonic() + ttl,
        )

    def invalidate(self, key: str) -> None:
        """Remove a specific key from the cache.

        Args:
            key: The cache key to remove.
        """
        self._store.pop(key, None)

    def clear(self) -> None:
        """Remove all entries from the cache."""
        self._store.clear()


# ---------------------------------------------------------------------------
# Client
# ---------------------------------------------------------------------------


def _get_token() -> Optional[str]:
    """Resolve the Figma API token from environment.

    Returns:
        The FIGMA_TOKEN value, or None if not set.
    """
    token = os.environ.get("FIGMA_TOKEN", "")
    return token if token else None


def _build_rate_limit_error(response: httpx.Response) -> FigmaRateLimitError:
    """Parse rate-limit headers from a 429 response and build the exception.

    Args:
        response: The httpx response with status 429.

    Returns:
        FigmaRateLimitError with parsed retry_after, rate_limit_type, plan_tier.
    """
    retry_after_raw = response.headers.get("Retry-After")
    try:
        retry_after = float(retry_after_raw) if retry_after_raw else None
    except (ValueError, TypeError):
        # Retry-After can be an HTTP-date string per spec — fall back gracefully
        retry_after = None
    rate_limit_type = response.headers.get("X-Figma-Rate-Limit-Type")
    plan_tier = response.headers.get("X-Figma-Plan-Tier")

    msg = "Rate limit exceeded (429)."
    if retry_after is not None:
        msg += f" Retry after {retry_after:.0f}s."
    if rate_limit_type:
        msg += f" Limit type: {rate_limit_type}."
    if plan_tier:
        msg += (
            f" Plan tier: {plan_tier}."
            " NOTE: View/Collab seats are limited to ~6 API requests/month."
            " Consider upgrading your Figma plan if you hit this limit frequently."
        )
    return FigmaRateLimitError(
        msg,
        retry_after=retry_after,
        rate_limit_type=rate_limit_type,
        plan_tier=plan_tier,
    )


def _raise_4xx_error(status: int, response: httpx.Response) -> None:
    """Raise the typed exception for a known 4xx status code.

    Handles 400, 403, 404, and 429. No-ops for unrecognised codes.

    Args:
        status: The HTTP status code.
        response: The httpx response object.
    """
    if status == 400:
        raise FigmaBadRequestError(
            f"Bad request: {response.text}. Check that node IDs are valid "
            f"colon-separated pairs (e.g., '1:3').",
            status_code=400,
        )
    if status == 403:
        raise FigmaAuthError(
            "Access denied (403). Your FIGMA_TOKEN may be invalid, expired, "
            "or lack access to this file. Generate a new token at "
            "https://www.figma.com/developers/api#access-tokens",
            status_code=403,
        )
    if status == 404:
        raise FigmaNotFoundError(
            "File or node not found (404). Verify the file key and node ID "
            "are correct and that the file has not been deleted.",
            status_code=404,
        )
    if status == 429:
        raise _build_rate_limit_error(response)


def _handle_error_response(response: httpx.Response) -> None:
    """Inspect an HTTP response and raise the appropriate typed exception.

    Raises:
        FigmaAuthError: On 403.
        FigmaNotFoundError: On 404.
        FigmaRateLimitError: On 429, with parsed rate-limit headers.
        FigmaBadRequestError: On 400.
        FigmaAPIError: On any other non-2xx status.
    """
    status = response.status_code
    if 200 <= status < 300:
        return
    _raise_4xx_error(status, response)
    logger.debug("Figma API error response body (HTTP %d): %s", status, response.text[:500])
    raise FigmaAPIError(
        f"Figma API error (HTTP {status}). See server logs for details.",
        status_code=status,
    )


class FigmaClient:
    """Async Figma REST API client with caching, rate-limit handling, and Desktop MCP fallback.

    Uses a shared httpx.AsyncClient for connection pooling. All responses
    are cached with two-tier TTLs (file data vs image URLs).

    Backend selection is automatic:
      1. REST API — used when FIGMA_TOKEN is set.
      2. Desktop MCP — used when FIGMA_TOKEN is absent but the Figma Desktop
         app is running locally (http://127.0.0.1:3845).
      3. Error — raised if neither backend is available.

    Cache keys include the active backend to prevent cross-contamination
    between REST and Desktop MCP responses.

    Usage::

        async with FigmaClient() as client:
            file_data = await client.get_file("abc123", depth=2)
            nodes = await client.get_nodes("abc123", ["1:3", "4:5"])
            images = await client.get_images("abc123", ["1:3"], format="png")
    """

    def __init__(
        self,
        *,
        file_cache_ttl: int = _DEFAULT_FILE_CACHE_TTL,
        image_cache_ttl: int = _DEFAULT_IMAGE_CACHE_TTL,
        timeout: float = _DEFAULT_TIMEOUT,
    ) -> None:
        """Initialize the Figma client.

        Args:
            file_cache_ttl: TTL in seconds for file/node response cache.
            image_cache_ttl: TTL in seconds for image export URL cache.
            timeout: HTTP request timeout in seconds.
        """
        self._cache = ResponseCache(
            file_ttl=file_cache_ttl,
            image_ttl=image_cache_ttl,
        )
        self._timeout = timeout
        self._client: Optional[httpx.AsyncClient] = None
        # Backend state: "unknown" until first _ensure_client() call.
        # Values: "rest" | "desktop" | "unknown"
        self._backend: str = "unknown"
        self._desktop_bridge: Optional[Any] = None  # DesktopMCPBridge, lazily imported

    def _create_rest_client(self, token: str) -> httpx.AsyncClient:
        """Create and configure a new httpx REST client with the given token.

        Args:
            token: The Figma personal access token.

        Returns:
            A configured httpx.AsyncClient ready for API calls.
        """
        return httpx.AsyncClient(
            base_url=_BASE_URL,
            headers={"X-Figma-Token": token},
            timeout=self._timeout,
        )

    async def _probe_desktop_backend(self) -> Optional[Any]:
        """Probe the Figma Desktop MCP server at 127.0.0.1:3845.

        Returns:
            A connected DesktopMCPBridge instance if the Desktop app is
            reachable, or None if it is not available.
        """
        from figma_desktop_bridge import DesktopMCPBridge  # noqa: PLC0415
        bridge = DesktopMCPBridge(timeout=self._timeout)
        if await bridge.is_available():
            return bridge
        await bridge.close()
        return None

    async def _select_new_backend(self) -> Optional[httpx.AsyncClient]:
        """Select a backend when the current backend is "unknown".

        Tries REST (FIGMA_TOKEN) first, then Desktop MCP, then raises.

        Returns:
            The httpx.AsyncClient for REST, or None for Desktop MCP.

        Raises:
            FigmaAPIError: If neither backend is available.
        """
        token = _get_token()
        if token:
            self._client = self._create_rest_client(token)
            self._backend = "rest"
            logger.debug("FigmaClient: selected REST backend.")
            return self._client

        logger.debug("FIGMA_TOKEN not set; probing Figma Desktop MCP server.")
        bridge = await self._probe_desktop_backend()
        if bridge is not None:
            self._desktop_bridge = bridge
            self._backend = "desktop"
            logger.info("FigmaClient: selected Desktop MCP backend (127.0.0.1:3845).")
            return None

        raise FigmaAPIError(
            "No Figma backend available. Either:\n"
            "  1. Set the FIGMA_TOKEN environment variable to your Personal Access Token, or\n"
            "  2. Open the Figma Desktop app (required for Desktop MCP at 127.0.0.1:3845).",
            status_code=0,
        )

    async def _ensure_client(self) -> Optional[httpx.AsyncClient]:
        """Lazily create the REST client OR select the Desktop MCP backend.

        Returns:
            The shared httpx.AsyncClient for REST calls, or None when the
            Desktop MCP backend has been selected.

        Raises:
            FigmaAPIError: If no backend is available.
        """
        # Fast path: REST client already created.
        if self._backend == "rest" and self._client is not None and not self._client.is_closed:
            return self._client
        # Fast path: Desktop backend already confirmed.
        if self._backend == "desktop":
            return None
        # Backend unknown — select now (runs once).
        return await self._select_new_backend()

    async def close(self) -> None:
        """Close the underlying HTTP client(s) and clear the cache."""
        if self._client is not None and not self._client.is_closed:
            await self._client.aclose()
        if self._desktop_bridge is not None:
            await self._desktop_bridge.close()
            self._desktop_bridge = None
        self._backend = "unknown"
        self._cache.clear()

    async def __aenter__(self) -> FigmaClient:
        """Enter the async context manager."""
        return self

    async def __aexit__(self, *exc: object) -> None:
        """Exit the async context manager and close the client."""
        await self.close()

    async def _execute_http_request(
        self, client: httpx.AsyncClient, method: str, path: str, **kwargs: Any
    ) -> httpx.Response:
        """Execute an HTTP request, wrapping transport errors as FigmaAPIError.

        Args:
            client: The httpx async client to use.
            method: HTTP method (GET, POST, etc.).
            path: API path (e.g., /v1/files/abc123).
            **kwargs: Additional httpx request arguments.

        Returns:
            The raw httpx response.

        Raises:
            FigmaAPIError: On timeout or connection-level errors.
        """
        try:
            return await client.request(method, path, **kwargs)
        except httpx.TimeoutException as exc:
            raise FigmaAPIError(
                f"Request timed out after {self._timeout}s: {path}",
                status_code=0,
            ) from exc
        except httpx.HTTPError as exc:
            raise FigmaAPIError(
                f"HTTP connection error: {exc}",
                status_code=0,
            ) from exc

    async def _request(self, method: str, path: str, **kwargs: Any) -> Any:
        """Send an HTTP request and return the parsed JSON response.

        Wraps httpx request errors with FigmaAPIError for consistent
        error handling at the tool layer.

        On FigmaAuthError, resets the backend to "unknown" so that the next
        call can re-probe and potentially fall back to the Desktop MCP.

        Args:
            method: HTTP method (GET, POST, etc.).
            path: API path (e.g., /v1/files/abc123).
            **kwargs: Additional httpx request arguments.

        Returns:
            Parsed JSON response data.

        Raises:
            FigmaAPIError: On any HTTP or connection error.
            FigmaAuthError: On 403 (token invalid/expired).
        """
        client = await self._ensure_client()
        response = await self._execute_http_request(client, method, path, **kwargs)

        try:
            _handle_error_response(response)
        except FigmaAuthError:
            # Reset backend so the next call can re-probe Desktop MCP fallback.
            logger.warning(
                "FigmaAuthError on REST backend — resetting backend to allow Desktop fallback."
            )
            self._backend = "unknown"
            raise

        return response.json()

    def _build_file_params(self, depth: int, branch_key: Optional[str]) -> dict[str, str]:
        """Build query parameters for a /v1/files request.

        Args:
            depth: Node tree traversal depth.
            branch_key: Optional branch key for branched files.

        Returns:
            Dict of query parameters.
        """
        params: dict[str, str] = {
            "depth": str(depth),
            "geometry": "paths",
        }
        if branch_key:
            params["branch_data"] = "true"
        return params

    async def get_file(
        self,
        file_key: str,
        *,
        depth: int = 2,
        branch_key: Optional[str] = None,
    ) -> dict[str, Any]:
        """Fetch a Figma file with depth-limited traversal.

        Uses depth=2 by default to get the top-level structure without
        pulling the entire deep tree. Use get_nodes() for detailed subtrees.

        Routes to the Desktop MCP backend when FIGMA_TOKEN is not set and
        the Figma Desktop app is running.

        Args:
            file_key: The Figma file key.
            depth: How deep to traverse the node tree (default 2).
            branch_key: Optional branch key for branched files.

        Returns:
            The Figma file JSON response.
        """
        depth = min(depth, 10)  # SEC-P3-002: clamp depth to prevent oversized API responses
        await self._ensure_client()  # Resolve backend before building cache key.
        cache_key = f"file:{self._backend}:{file_key}:{branch_key}:{depth}"
        cached = self._cache.get(cache_key)
        if cached is not None:
            return cached

        if self._backend == "desktop":
            data = await self._desktop_bridge.get_file(file_key, depth=depth)
            self._cache.set(cache_key, data)
            return data

        params = self._build_file_params(depth, branch_key)
        data = await self._request("GET", f"/v1/files/{file_key}", params=params)
        self._cache.set(cache_key, data)
        return data

    def _build_nodes_params(self, ids_str: str) -> dict[str, str]:
        """Build query parameters for a /v1/files/{key}/nodes request.

        Args:
            ids_str: Comma-separated node ID string.

        Returns:
            Dict of query parameters.
        """
        return {
            "ids": ids_str,
            "geometry": "paths",
        }

    async def get_nodes(
        self,
        file_key: str,
        node_ids: list[str],
        *,
        branch_key: Optional[str] = None,
    ) -> dict[str, Any]:
        """Fetch specific nodes from a Figma file.

        Useful for depth-limited fetching: first get_file(depth=2) to see
        the structure, then get_nodes() for specific subtrees.

        Routes to the Desktop MCP backend when active (Desktop MCP fetches
        nodes sequentially with a circuit breaker for resilience).

        Args:
            file_key: The Figma file key.
            node_ids: List of node IDs in colon format (e.g., ["1:3", "4:5"]).
            branch_key: Optional branch key.

        Returns:
            The Figma nodes JSON response.
        """
        await self._ensure_client()  # Resolve backend before building cache key.
        ids_str = ",".join(node_ids)
        cache_key = f"nodes:{self._backend}:{file_key}:{branch_key}:{ids_str}"
        cached = self._cache.get(cache_key)
        if cached is not None:
            return cached

        if self._backend == "desktop":
            data = await self._desktop_bridge.get_nodes(file_key, node_ids)
            self._cache.set(cache_key, data)
            return data

        params = self._build_nodes_params(ids_str)
        data = await self._request(
            "GET", f"/v1/files/{file_key}/nodes", params=params
        )
        self._cache.set(cache_key, data)
        return data

    def _build_images_params(
        self, ids_str: str, format: str, scale: float
    ) -> dict[str, str]:
        """Build query parameters for a /v1/images request.

        Args:
            ids_str: Comma-separated node ID string.
            format: Image format (png, svg, jpg, pdf).
            scale: Export scale factor.

        Returns:
            Dict of query parameters.
        """
        return {
            "ids": ids_str,
            "format": format,
            "scale": str(scale),
        }

    async def _fetch_images_rest(
        self,
        file_key: str,
        ids_str: str,
        cache_key: str,
        format: str,
        scale: float,
    ) -> dict[str, Optional[str]]:
        """Fetch image export URLs via the REST backend and populate the cache.

        Args:
            file_key: The Figma file key.
            ids_str: Comma-separated node ID string.
            cache_key: Cache key to store the result under.
            format: Image format (png, svg, jpg, pdf).
            scale: Export scale factor.

        Returns:
            Dict mapping node_id to image URL (or None if export failed).
        """
        params = self._build_images_params(ids_str, format, scale)
        data = await self._request("GET", f"/v1/images/{file_key}", params=params)
        images: dict[str, Optional[str]] = data.get("images", {})
        self._cache.set(cache_key, images, is_image=True)
        return images

    async def get_images(
        self,
        file_key: str,
        node_ids: list[str],
        *,
        format: str = "png",
        scale: float = 2.0,
    ) -> dict[str, Optional[str]]:
        """Export nodes as images and return download URLs.

        Image URLs are cached with a longer TTL than file data.
        Desktop MCP backend degrades gracefully (returns None values)
        if image export is not available via the Desktop app.

        Args:
            file_key: The Figma file key.
            node_ids: List of node IDs to export.
            format: Image format — "png", "svg", "jpg", or "pdf".
            scale: Export scale factor (default 2.0 for retina).

        Returns:
            Dict mapping node_id to image URL (or None if export failed).
        """
        await self._ensure_client()  # Resolve backend before building cache key.
        ids_str = ",".join(node_ids)
        cache_key = f"images:{self._backend}:{file_key}:{ids_str}:{format}:{scale}"
        cached = self._cache.get(cache_key)
        if cached is not None:
            return cached

        if self._backend == "desktop":
            images = await self._desktop_bridge.get_images(
                file_key, node_ids, format=format, scale=scale
            )
            self._cache.set(cache_key, images, is_image=True)
            return images

        return await self._fetch_images_rest(file_key, ids_str, cache_key, format, scale)
