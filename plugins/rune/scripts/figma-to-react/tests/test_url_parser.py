"""Tests for url_parser.py — Figma URL parsing and validation."""
from __future__ import annotations

import sys
from pathlib import Path

import pytest

# Add parent directory to path so we can import the module under test
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from url_parser import FigmaURLError, parse_figma_url  # noqa: E402


# ---------------------------------------------------------------------------
# Standard URL formats (7 types)
# ---------------------------------------------------------------------------

class TestStandardUrls:
    """Test parsing of all 7 supported Figma URL formats."""

    def test_design_url(self):
        """Parse /design/ URL (current canonical format)."""
        result = parse_figma_url(
            "https://www.figma.com/design/ABC123XYZabcdef789012/MyFile?node-id=1-3"
        )
        assert result["file_key"] == "ABC123XYZabcdef789012"
        assert result["type"] == "design"
        assert result["node_id"] == "1:3"

    def test_file_url(self):
        """Parse legacy /file/ URL."""
        result = parse_figma_url(
            "https://www.figma.com/file/ABC123XYZabcdef789012/MyFile"
        )
        assert result["file_key"] == "ABC123XYZabcdef789012"
        assert result["type"] == "file"

    def test_dev_url(self):
        """Parse /dev/ URL (Dev Mode)."""
        result = parse_figma_url(
            "https://figma.com/dev/ABC123XYZabcdef789012/MyFile?node-id=5-10"
        )
        assert result["file_key"] == "ABC123XYZabcdef789012"
        assert result["type"] == "dev"
        assert result["node_id"] == "5:10"

    def test_proto_url(self):
        """Parse /proto/ URL (Prototype)."""
        result = parse_figma_url(
            "https://www.figma.com/proto/ABC123XYZabcdef789012/MyProto"
        )
        assert result["file_key"] == "ABC123XYZabcdef789012"
        assert result["type"] == "proto"

    def test_board_url(self):
        """Parse /board/ URL (FigJam)."""
        result = parse_figma_url(
            "https://www.figma.com/board/ABC123XYZabcdef789012/MyBoard"
        )
        assert result["file_key"] == "ABC123XYZabcdef789012"
        assert result["type"] == "board"

    def test_slides_url(self):
        """Parse /slides/ URL."""
        result = parse_figma_url(
            "https://www.figma.com/slides/ABC123XYZabcdef789012/MySlides"
        )
        assert result["file_key"] == "ABC123XYZabcdef789012"
        assert result["type"] == "slides"

    def test_make_url(self):
        """Parse /make/ URL."""
        result = parse_figma_url(
            "https://www.figma.com/make/ABC123XYZabcdef789012/MyMake"
        )
        assert result["file_key"] == "ABC123XYZabcdef789012"
        assert result["type"] == "make"


# ---------------------------------------------------------------------------
# Branch URLs
# ---------------------------------------------------------------------------

class TestBranchUrls:
    """Test parsing of branch URLs."""

    def test_branch_url(self):
        """Parse URL with branch key."""
        result = parse_figma_url(
            "https://www.figma.com/design/ABC123XYZabcdef789012/branch/BR456def/MyFile?node-id=2-5"
        )
        assert result["file_key"] == "ABC123XYZabcdef789012"
        assert result["branch_key"] == "BR456def"
        assert result["node_id"] == "2:5"

    def test_branch_without_node_id(self):
        """Parse branch URL without node-id parameter."""
        result = parse_figma_url(
            "https://www.figma.com/design/ABC123XYZabcdef789012/branch/BR456/MyFile"
        )
        assert result["file_key"] == "ABC123XYZabcdef789012"
        assert result["branch_key"] == "BR456"
        assert result.get("node_id") is None or result.get("node_id") == ""


# ---------------------------------------------------------------------------
# Node ID conversion (hyphen to colon)
# ---------------------------------------------------------------------------

class TestNodeIdConversion:
    """Test hyphen-to-colon conversion for node IDs."""

    def test_hyphen_to_colon(self):
        """Node IDs in URLs use hyphens; API uses colons."""
        result = parse_figma_url(
            "https://figma.com/design/ABC123XYZabcdef789012/File?node-id=1-3"
        )
        assert result["node_id"] == "1:3"

    def test_url_encoded_colon(self):
        """Handle %3A URL encoding for colons."""
        result = parse_figma_url(
            "https://figma.com/design/ABC123XYZabcdef789012/File?node-id=1%3A3"
        )
        # After URL decoding, 1:3 should remain 1:3 (colon already present)
        assert result["node_id"] == "1:3"

    def test_complex_node_id(self):
        """Handle multi-level node IDs like 100-200."""
        result = parse_figma_url(
            "https://figma.com/design/ABC123XYZabcdef789012/File?node-id=100-200"
        )
        assert result["node_id"] == "100:200"

    def test_no_node_id(self):
        """URL without node-id should have None or empty node_id."""
        result = parse_figma_url(
            "https://figma.com/design/ABC123XYZabcdef789012/MyFile"
        )
        assert result.get("node_id") is None or result.get("node_id") == ""

    def test_multiple_query_params(self):
        """Extract node-id from URL with multiple query parameters."""
        result = parse_figma_url(
            "https://figma.com/design/ABC123XYZabcdef789012/File?t=abc&node-id=3-7&mode=dev"
        )
        assert result["node_id"] == "3:7"


# ---------------------------------------------------------------------------
# Invalid URLs
# ---------------------------------------------------------------------------

class TestInvalidUrls:
    """Test rejection of invalid Figma URLs."""

    def test_empty_string(self):
        """Empty string should raise ValueError."""
        with pytest.raises(FigmaURLError):
            parse_figma_url("")

    def test_non_figma_domain(self):
        """Non-Figma URLs should be rejected."""
        with pytest.raises(FigmaURLError):
            parse_figma_url("https://example.com/design/ABC123/File")

    def test_random_string(self):
        """Random non-URL string should be rejected."""
        with pytest.raises(FigmaURLError):
            parse_figma_url("not-a-url-at-all")

    def test_missing_file_key(self):
        """URL without file key should be rejected."""
        with pytest.raises(FigmaURLError):
            parse_figma_url("https://figma.com/design/")

    def test_unsupported_path(self):
        """URL with unsupported path segment should be rejected."""
        with pytest.raises(FigmaURLError):
            parse_figma_url("https://figma.com/unknown/ABC123/File")


# ---------------------------------------------------------------------------
# SSRF Prevention
# ---------------------------------------------------------------------------

class TestSsrfPrevention:
    """Test that non-Figma hostnames are blocked."""

    def test_localhost_blocked(self):
        """Localhost URLs must be blocked."""
        with pytest.raises(FigmaURLError):
            parse_figma_url("https://localhost/design/ABC123XYZabcdef789012/File")

    def test_ip_address_blocked(self):
        """IP address URLs must be blocked."""
        with pytest.raises(FigmaURLError):
            parse_figma_url("https://127.0.0.1/design/ABC123XYZabcdef789012/File")

    def test_internal_domain_blocked(self):
        """Internal/private domain URLs must be blocked."""
        with pytest.raises(FigmaURLError):
            parse_figma_url("https://internal.corp/design/ABC123XYZabcdef789012/File")

    def test_figma_subdomain_spoofing_blocked(self):
        """Subdomains that aren't www.figma.com or figma.com should be blocked."""
        with pytest.raises(FigmaURLError):
            parse_figma_url("https://evil.figma.com.attacker.com/design/ABC123/File")


# ---------------------------------------------------------------------------
# Edge cases
# ---------------------------------------------------------------------------

class TestEdgeCases:
    """Test edge cases and unusual but valid inputs."""

    def test_url_without_www(self):
        """figma.com without www prefix should work."""
        result = parse_figma_url(
            "https://figma.com/design/ABC123XYZabcdef789012/MyFile"
        )
        assert result["file_key"] == "ABC123XYZabcdef789012"

    def test_url_with_www(self):
        """www.figma.com should work."""
        result = parse_figma_url(
            "https://www.figma.com/design/ABC123XYZabcdef789012/MyFile"
        )
        assert result["file_key"] == "ABC123XYZabcdef789012"

    def test_url_with_trailing_slash(self):
        """URL with trailing slash should still parse."""
        result = parse_figma_url(
            "https://figma.com/design/ABC123XYZabcdef789012/MyFile/"
        )
        assert result["file_key"] == "ABC123XYZabcdef789012"

    def test_url_with_special_chars_in_name(self):
        """File name with special characters should parse."""
        result = parse_figma_url(
            "https://figma.com/design/ABC123XYZabcdef789012/My%20File%20(v2)"
        )
        assert result["file_key"] == "ABC123XYZabcdef789012"

    def test_http_rejected(self):
        """HTTP URLs must be rejected — only HTTPS is allowed (SEC-001)."""
        with pytest.raises(FigmaURLError):
            parse_figma_url(
                "http://figma.com/design/ABC123XYZabcdef789012/MyFile"
            )


# ---------------------------------------------------------------------------
# Additional edge cases
# ---------------------------------------------------------------------------


class TestInvalidUrlEdgeCases:
    """Additional edge cases for invalid and malformed URL inputs."""

    def test_none_input_raises_error(self):
        """None input should raise FigmaURLError."""
        with pytest.raises(FigmaURLError):
            parse_figma_url(None)

    def test_whitespace_only_string_raises_error(self):
        """Whitespace-only string should raise FigmaURLError."""
        with pytest.raises(FigmaURLError):
            parse_figma_url("   ")

    def test_integer_input_raises_error(self):
        """Non-string input (integer) should raise FigmaURLError."""
        with pytest.raises(FigmaURLError):
            parse_figma_url(12345)

    def test_empty_file_key_segment_raises_error(self):
        """URL where file_key segment is empty raises FigmaURLError."""
        with pytest.raises(FigmaURLError):
            parse_figma_url("https://figma.com/design//MyFile")

    def test_malformed_url_no_scheme(self):
        """URL without scheme should raise FigmaURLError."""
        with pytest.raises(FigmaURLError):
            parse_figma_url("figma.com/design/ABC123XYZabcdef789012/MyFile")

    def test_url_with_ftp_scheme_rejected(self):
        """FTP URL scheme must be rejected."""
        with pytest.raises(FigmaURLError):
            parse_figma_url("ftp://figma.com/design/ABC123XYZabcdef789012/MyFile")

    def test_url_path_only_raises_error(self):
        """Path-only string (no scheme/host) should raise FigmaURLError."""
        with pytest.raises(FigmaURLError):
            parse_figma_url("/design/ABC123XYZabcdef789012/MyFile")

    def test_invalid_node_id_with_letters_raises_error(self):
        """node-id with letters in the numeric part should raise FigmaURLError."""
        with pytest.raises(FigmaURLError):
            parse_figma_url(
                "https://figma.com/design/ABC123XYZabcdef789012/File?node-id=abc-xyz"
            )

    def test_figma_community_url_rejected(self):
        """Figma community URLs are not file URLs and should be rejected."""
        with pytest.raises(FigmaURLError):
            parse_figma_url("https://figma.com/community/file/ABC123XYZabcdef789012")

    def test_url_with_unicode_in_file_key_position_rejected(self):
        """File key position with unicode chars should not parse as valid key."""
        with pytest.raises(FigmaURLError):
            parse_figma_url(
                "https://figma.com/design/ABCD🔥1234567890123/MyFile"
            )


class TestMissingNodeIdEdgeCases:
    """Edge cases around missing or boundary node-id values."""

    def test_node_id_missing_returns_none(self):
        """URL without node-id should return None for node_id field."""
        result = parse_figma_url(
            "https://figma.com/design/ABC123XYZabcdef789012/MyFile"
        )
        assert result["node_id"] is None

    def test_node_id_empty_value_returns_none(self):
        """node-id with empty value in query string should return None."""
        result = parse_figma_url(
            "https://figma.com/design/ABC123XYZabcdef789012/MyFile?node-id="
        )
        assert result["node_id"] is None

    def test_node_id_zero_boundary(self):
        """node-id of '0-0' (zero:zero boundary) should parse to '0:0'."""
        result = parse_figma_url(
            "https://figma.com/design/ABC123XYZabcdef789012/File?node-id=0-0"
        )
        assert result["node_id"] == "0:0"

    def test_node_id_large_number_boundary(self):
        """Very large node-id numbers should parse correctly."""
        result = parse_figma_url(
            "https://figma.com/design/ABC123XYZabcdef789012/File?node-id=999999-888888"
        )
        assert result["node_id"] == "999999:888888"


class TestSpecialCharsEdgeCases:
    """Edge cases for special characters in Figma URLs."""

    def test_url_with_unicode_in_filename(self):
        """URL with unicode characters URL-encoded in filename should parse file_key."""
        result = parse_figma_url(
            "https://figma.com/design/ABC123XYZabcdef789012/%E3%83%87%E3%82%B6%E3%82%A4%E3%83%B3"
        )
        assert result["file_key"] == "ABC123XYZabcdef789012"

    def test_url_with_multiple_special_chars_in_name(self):
        """URL with multiple URL-encoded special chars in file name should parse."""
        result = parse_figma_url(
            "https://figma.com/design/ABC123XYZabcdef789012/My%20Design%20%28Draft%29"
        )
        assert result["file_key"] == "ABC123XYZabcdef789012"

    def test_url_without_file_title_segment(self):
        """URL with type and file_key but no title segment should parse."""
        result = parse_figma_url(
            "https://figma.com/design/ABC123XYZabcdef789012"
        )
        assert result["file_key"] == "ABC123XYZabcdef789012"
        assert result["type"] == "design"

    def test_branch_key_missing_when_no_branch(self):
        """URL without branch should have None branch_key."""
        result = parse_figma_url(
            "https://figma.com/design/ABC123XYZabcdef789012/MyFile"
        )
        assert result["branch_key"] is None

    def test_fragment_identifier_in_url(self):
        """URL with fragment identifier (#...) should parse file_key correctly."""
        result = parse_figma_url(
            "https://figma.com/design/ABC123XYZabcdef789012/MyFile#section"
        )
        assert result["file_key"] == "ABC123XYZabcdef789012"

    def test_url_with_extra_query_params_before_node_id(self):
        """URL with query params before node-id should extract node-id correctly."""
        result = parse_figma_url(
            "https://figma.com/design/ABC123XYZabcdef789012/File?foo=bar&node-id=5-10&baz=qux"
        )
        assert result["node_id"] == "5:10"
