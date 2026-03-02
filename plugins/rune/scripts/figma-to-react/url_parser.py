"""
Figma URL Parser

Parses Figma URLs into structured components (file_key, node_id, type, branch_key).
Supports 7 URL types: file, design, proto, board, slides, dev, make.
Handles branch URLs and encoded node-id formats.

Security:
  SEC-001: Hostname validation prevents SSRF via crafted URLs.
"""

from __future__ import annotations

import re
from typing import Optional
from urllib.parse import ParseResult, unquote, urlparse


class FigmaURLError(ValueError):
    """Raised when a Figma URL cannot be parsed."""


# Allowed hostnames — prevents SSRF by restricting to Figma domains only.
_ALLOWED_HOSTS = frozenset({"figma.com", "www.figma.com"})

# URL path types that correspond to Figma document URLs.
# Each maps to the path segment that appears after the hostname.
_URL_TYPES = frozenset({"file", "design", "proto", "board", "slides", "dev", "make"})

# Pattern: /{type}/{file_key}[/branch/{branch_key}][/title][?node-id=...]
# file_key is always the segment after the type.
_PATH_RE = re.compile(
    r"^/(?P<type>" + "|".join(_URL_TYPES) + r")"
    r"/(?P<file_key>[A-Za-z0-9]+)"
    r"(?:/branch/(?P<branch_key>[A-Za-z0-9]+))?"
    r"(?:/[^?]*)?"  # optional title segment (ignored)
    r"$"
)


def _normalize_node_id(raw: str) -> str:
    """Convert a raw node-id value to canonical colon-separated format.

    Figma encodes node IDs as ``1-3`` in URLs (hyphen) and ``1%3A3``
    (percent-encoded colon). The canonical API format uses colons: ``1:3``.

    Args:
        raw: The raw node-id query parameter value.

    Returns:
        Node ID with colons as separators.

    Raises:
        FigmaURLError: If the normalized node ID contains unexpected characters.
    """
    # First decode any percent-encoding (%3A → :)
    decoded = unquote(raw)
    # Convert hyphens to colons only if the decoded string has no colons yet.
    # If colons are already present (from %3A decoding), hyphens are literal.
    # This prevents corrupting multi-segment node IDs (e.g., "1-3-5" → "1:3:5").
    if ":" not in decoded:
        normalized = decoded.replace("-", ":")
    else:
        normalized = decoded
    # Validate: Figma node IDs contain only digits, colons, and commas
    if not re.match(r"^[\d:,]+$", normalized):
        raise FigmaURLError(
            f"Invalid node-id format '{normalized}'. Expected digits, colons, and commas only."
        )
    return normalized


def _validate_figma_url(url: str) -> ParseResult:
    """Validate URL string, hostname, and scheme for Figma SSRF safety.

    Args:
        url: Raw URL string to validate.

    Returns:
        Parsed URL result from urlparse.

    Raises:
        FigmaURLError: If url is empty, has a bad hostname, or non-https scheme.
    """
    if not url or not isinstance(url, str):
        raise FigmaURLError("URL must be a non-empty string")

    parsed = urlparse(url)

    # SEC-001: SSRF prevention — only allow figma.com hostnames.
    hostname = (parsed.hostname or "").lower()
    if hostname not in _ALLOWED_HOSTS:
        raise FigmaURLError(
            f"Invalid hostname '{hostname}'. Only figma.com URLs are accepted (SSRF prevention)."
        )

    if parsed.scheme != "https":
        raise FigmaURLError(
            f"Invalid scheme '{parsed.scheme}'. Only https is accepted."
        )

    return parsed


def _match_figma_path(path: str) -> re.Match:
    """Match a Figma URL path against the known URL type pattern.

    Args:
        path: The path component of the URL (e.g., /design/abc123/Title).

    Returns:
        Regex match object with groups: type, file_key, branch_key.

    Raises:
        FigmaURLError: If the path does not match any known Figma URL pattern.
    """
    match = _PATH_RE.match(path)
    if not match:
        raise FigmaURLError(
            f"Cannot parse Figma URL path: {path}. "
            f"Expected /<type>/<file_key>[/branch/<branch_key>][/title] "
            f"where type is one of: {', '.join(sorted(_URL_TYPES))}"
        )
    return match


def _extract_node_id(query: str) -> Optional[str]:
    """Extract and normalize the node-id query parameter from a URL query string.

    Args:
        query: Raw query string from URL (e.g., "node-id=1-3&t=abc").

    Returns:
        Normalized node ID (colon-separated), or None if not present.

    Raises:
        FigmaURLError: If the node-id value is malformed.
    """
    if not query:
        return None
    for param in query.split("&"):
        if param.startswith("node-id="):
            raw_value = param[len("node-id="):]
            if raw_value:
                return _normalize_node_id(raw_value)
            break
    return None


def parse_figma_url(url: str) -> dict[str, Optional[str]]:
    """Parse a Figma URL into its structural components.

    Supports 7 URL types:
      - ``/file/``   — classic file URL
      - ``/design/`` — new design URL
      - ``/proto/``  — prototype URL
      - ``/board/``  — FigJam board URL
      - ``/slides/`` — slides URL
      - ``/dev/``    — dev mode URL
      - ``/make/``   — make URL

    Branch URLs (``/design/{key}/branch/{branch_key}/...``) are also handled.

    Args:
        url: A full Figma URL string (must start with https://figma.com/...).

    Returns:
        A dict with keys:
          - ``file_key``: The Figma file key (always present).
          - ``node_id``: The node ID in colon format, or None.
          - ``type``: The URL type (e.g., "design", "file").
          - ``branch_key``: The branch key, or None.

    Raises:
        FigmaURLError: If the URL is not a valid Figma document URL.
    """
    parsed = _validate_figma_url(url)
    match = _match_figma_path(parsed.path)
    node_id = _extract_node_id(parsed.query)

    return {
        "file_key": match.group("file_key"),
        "node_id": node_id,
        "type": match.group("type"),
        "branch_key": match.group("branch_key"),
    }
