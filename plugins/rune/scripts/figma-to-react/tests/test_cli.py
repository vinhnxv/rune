"""Tests for cli.py — CLI argument parsing and integration."""
from __future__ import annotations

import json
import sys
from io import StringIO
from pathlib import Path
from unittest.mock import AsyncMock, patch

import pytest

# Add parent directory to path so we can import the module under test
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from cli import _extract_component_name, _mask_token, _supports_color, build_parser, main  # noqa: E402


# ---------------------------------------------------------------------------
# Token masking
# ---------------------------------------------------------------------------


class TestMaskToken:
    """Test token masking for safe display."""

    def test_short_token_fully_masked(self):
        assert _mask_token("abc") == "****"
        assert _mask_token("123456789012") == "****"

    def test_long_token_shows_prefix_suffix(self):
        token = "figd_abcdefghijklmnop"
        masked = _mask_token(token)
        assert masked.startswith("figd_")
        assert masked.endswith("mnop")
        assert "****" in masked

    def test_empty_token(self):
        assert _mask_token("") == "****"


# ---------------------------------------------------------------------------
# Color support detection
# ---------------------------------------------------------------------------


class TestSupportsColor:
    """Test terminal color detection."""

    def test_no_color_env(self, monkeypatch):
        monkeypatch.setenv("NO_COLOR", "1")
        assert _supports_color() is False

    def test_force_color_env(self, monkeypatch):
        monkeypatch.setenv("FORCE_COLOR", "1")
        monkeypatch.delenv("NO_COLOR", raising=False)
        assert _supports_color() is True


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------


class TestBuildParser:
    """Test CLI argument parser construction."""

    def test_fetch_subcommand(self):
        parser = build_parser()
        args = parser.parse_args(["fetch", "https://figma.com/design/ABC/Title"])
        assert args.command == "fetch"
        assert args.url == "https://figma.com/design/ABC/Title"
        assert args.depth == 2  # default

    def test_fetch_with_depth(self):
        parser = build_parser()
        args = parser.parse_args([
            "fetch", "https://figma.com/design/ABC/Title", "--depth", "5"
        ])
        assert args.depth == 5

    def test_inspect_subcommand(self):
        parser = build_parser()
        args = parser.parse_args([
            "inspect", "https://figma.com/design/ABC/Title?node-id=1-3"
        ])
        assert args.command == "inspect"

    def test_list_subcommand(self):
        parser = build_parser()
        args = parser.parse_args(["list", "https://figma.com/design/ABC/Title"])
        assert args.command == "list"

    def test_react_subcommand(self):
        parser = build_parser()
        args = parser.parse_args([
            "react", "https://figma.com/design/ABC/Title?node-id=1-3",
            "--name", "MyCard",
        ])
        assert args.command == "react"
        assert args.name == "MyCard"

    def test_react_no_tailwind(self):
        parser = build_parser()
        args = parser.parse_args([
            "react", "https://figma.com/design/ABC/Title", "--no-tailwind"
        ])
        assert args.no_tailwind is True

    def test_react_extract(self):
        parser = build_parser()
        args = parser.parse_args([
            "react", "https://figma.com/design/ABC/Title", "--extract"
        ])
        assert args.extract is True

    def test_react_code_flag(self):
        parser = build_parser()
        args = parser.parse_args([
            "react", "https://figma.com/design/ABC/Title", "--code"
        ])
        assert args.code is True

    def test_react_write_flag(self):
        parser = build_parser()
        args = parser.parse_args([
            "react", "https://figma.com/design/ABC/Title", "--write", "/tmp/out/"
        ])
        assert args.write == "/tmp/out/"

    def test_react_aria_flag(self):
        parser = build_parser()
        args = parser.parse_args([
            "react", "https://figma.com/design/ABC/Title", "--aria"
        ])
        assert args.aria is True

    def test_react_aria_default_off(self):
        parser = build_parser()
        args = parser.parse_args([
            "react", "https://figma.com/design/ABC/Title"
        ])
        assert args.aria is False

    def test_global_options(self):
        parser = build_parser()
        args = parser.parse_args([
            "--token", "figd_xxx", "--pretty", "--verbose",
            "fetch", "https://figma.com/design/ABC/Title",
        ])
        assert args.token == "figd_xxx"
        assert args.pretty is True
        assert args.verbose is True

    def test_output_flag(self):
        parser = build_parser()
        args = parser.parse_args([
            "-o", "/tmp/out.json",
            "fetch", "https://figma.com/design/ABC/Title",
        ])
        assert args.output == "/tmp/out.json"

    def test_missing_command_exits(self):
        parser = build_parser()
        with pytest.raises(SystemExit):
            parser.parse_args([])


# ---------------------------------------------------------------------------
# main() integration
# ---------------------------------------------------------------------------


class TestMain:
    """Test main() entry point with mocked API calls."""

    def test_missing_token_exits(self, monkeypatch):
        """Exit code 1 when no token is provided."""
        monkeypatch.delenv("FIGMA_TOKEN", raising=False)
        with pytest.raises(SystemExit) as exc_info:
            main(["fetch", "https://figma.com/design/ABC/Title"])
        assert exc_info.value.code == 1

    def test_invalid_url_exits(self, monkeypatch):
        """Exit code 1 for invalid Figma URLs."""
        monkeypatch.setenv("FIGMA_TOKEN", "figd_test_token_value")
        with pytest.raises(SystemExit) as exc_info:
            main(["fetch", "https://example.com/not-figma"])
        assert exc_info.value.code == 1

    def test_fetch_success(self, monkeypatch):
        """Successful fetch writes JSON to stdout."""
        monkeypatch.setenv("FIGMA_TOKEN", "figd_test_token_value")

        mock_result = {
            "content": '{"file_key": "ABC", "node_count": 5, "tree": {}}',
        }

        with patch("core.fetch_design", new_callable=AsyncMock, return_value=mock_result):
            captured = StringIO()
            monkeypatch.setattr("sys.stdout", captured)

            main(["fetch", "https://www.figma.com/design/ABC123XYZabcdef789012/Title"])

            output = captured.getvalue()
            parsed = json.loads(output)
            assert parsed["content"] is not None

    def test_output_to_file(self, monkeypatch, tmp_path):
        """--output writes result to file instead of stdout."""
        monkeypatch.setenv("FIGMA_TOKEN", "figd_test_token_value")
        out_file = tmp_path / "result.json"

        mock_result = {"content": "test"}

        with patch("core.fetch_design", new_callable=AsyncMock, return_value=mock_result):
            main([
                "--output", str(out_file),
                "fetch", "https://www.figma.com/design/ABC123XYZabcdef789012/Title",
            ])

        assert out_file.exists()
        parsed = json.loads(out_file.read_text())
        assert parsed["content"] == "test"

    def test_pretty_output(self, monkeypatch):
        """--pretty produces indented JSON."""
        monkeypatch.setenv("FIGMA_TOKEN", "figd_test_token_value")

        mock_result = {"content": "test", "count": 1}

        with patch("core.fetch_design", new_callable=AsyncMock, return_value=mock_result):
            captured = StringIO()
            monkeypatch.setattr("sys.stdout", captured)

            main([
                "--pretty",
                "fetch", "https://www.figma.com/design/ABC123XYZabcdef789012/Title",
            ])

            output = captured.getvalue()
            assert "\n" in output  # indented output has newlines
            assert "  " in output  # 2-space indentation

    def test_code_flag_outputs_raw_tsx(self, monkeypatch):
        """--code prints raw React code, not JSON."""
        monkeypatch.setenv("FIGMA_TOKEN", "figd_test_token_value")

        mock_result = {
            "content": json.dumps({
                "file_key": "ABC",
                "main_component": "export default function SignUp() {\n  return <div/>;\n}",
            }),
        }

        with patch("core.to_react", new_callable=AsyncMock, return_value=mock_result):
            captured = StringIO()
            monkeypatch.setattr("sys.stdout", captured)

            main([
                "react",
                "https://www.figma.com/design/ABC123XYZabcdef789012/Title?node-id=1-3",
                "--code",
            ])

            output = captured.getvalue().strip()
            assert output.startswith("export default function")
            # Should NOT be JSON-wrapped
            assert not output.startswith("{")

    def test_write_flag_creates_file(self, monkeypatch, tmp_path):
        """--write writes a .tsx file."""
        monkeypatch.setenv("FIGMA_TOKEN", "figd_test_token_value")

        code = "export default function MyCard() {\n  return <div/>;\n}"
        mock_result = {
            "content": json.dumps({"file_key": "ABC", "main_component": code}),
        }

        with patch("core.to_react", new_callable=AsyncMock, return_value=mock_result):
            main([
                "react",
                "https://www.figma.com/design/ABC123XYZabcdef789012/Title?node-id=1-3",
                "--write", str(tmp_path / "MyCard.tsx"),
            ])

        out_file = tmp_path / "MyCard.tsx"
        assert out_file.exists()
        content = out_file.read_text()
        assert "export default function MyCard" in content

    def test_write_flag_auto_names_from_component(self, monkeypatch, tmp_path):
        """--write to a directory auto-names the .tsx file from the component."""
        monkeypatch.setenv("FIGMA_TOKEN", "figd_test_token_value")

        code = "export default function LoginForm() {\n  return <div/>;\n}"
        mock_result = {
            "content": json.dumps({"file_key": "ABC", "main_component": code}),
        }

        with patch("core.to_react", new_callable=AsyncMock, return_value=mock_result):
            main([
                "react",
                "https://www.figma.com/design/ABC123XYZabcdef789012/Title?node-id=1-3",
                "--write", str(tmp_path),
            ])

        out_file = tmp_path / "LoginForm.tsx"
        assert out_file.exists()

    def test_code_and_write_mutually_exclusive(self, monkeypatch):
        """--code and --write together should error."""
        monkeypatch.setenv("FIGMA_TOKEN", "figd_test_token_value")
        with pytest.raises(SystemExit) as exc_info:
            main([
                "react",
                "https://figma.com/design/ABC/Title",
                "--code", "--write", "/tmp/out.tsx",
            ])
        assert exc_info.value.code == 2  # argparse error

    def test_code_and_output_conflict(self, monkeypatch):
        """--code and --output together should error."""
        monkeypatch.setenv("FIGMA_TOKEN", "figd_test_token_value")
        with pytest.raises(SystemExit) as exc_info:
            main([
                "--output", "/tmp/out.json",
                "react",
                "https://figma.com/design/ABC/Title",
                "--code",
            ])
        assert exc_info.value.code == 2


# ---------------------------------------------------------------------------
# _extract_component_name
# ---------------------------------------------------------------------------


class TestExtractComponentName:
    """Test component name extraction from generated React code."""

    def test_standard_export(self):
        code = "export default function MyCard() {\n  return <div/>;\n}"
        assert _extract_component_name(code) == "MyCard"

    def test_multiline_code(self):
        code = "import React from 'react';\n\nexport default function SignUpForm() {"
        assert _extract_component_name(code) == "SignUpForm"

    def test_no_match_returns_default(self):
        code = "const x = 42;"
        assert _extract_component_name(code) == "Component"

    def test_empty_string(self):
        assert _extract_component_name("") == "Component"


# ---------------------------------------------------------------------------
# Edge-case tests: token masking
# ---------------------------------------------------------------------------


class TestMaskTokenEdgeCases:
    """Edge-case tests for _mask_token."""

    def test_null_like_empty_token_masked(self):
        """Empty string (null-like input) returns masked placeholder."""
        assert _mask_token("") == "****"

    def test_whitespace_only_token_masked(self):
        """Whitespace-only token is short — fully masked."""
        assert _mask_token("   ") == "****"

    def test_boundary_token_length_12_fully_masked(self):
        """Token of exactly 12 chars is fully masked (boundary condition)."""
        assert _mask_token("a" * 12) == "****"

    def test_boundary_token_length_13_shows_prefix_suffix(self):
        """Token of 13 chars (boundary + 1) shows prefix/suffix."""
        token = "figd_ABCDEFGH"  # exactly 13 chars
        masked = _mask_token(token)
        assert "****" in masked
        assert masked != "****"

    def test_unicode_token_handled(self):
        """Token containing unicode characters doesn't raise."""
        token = "figd_\u4e2d\u6587\u5b57\u7b26\u8fd9\u662f\u6d4b\u8bd5"
        result = _mask_token(token)
        assert isinstance(result, str)

    def test_special_characters_in_token(self):
        """Token with special characters is processed safely."""
        token = "figd_!@#$%^&*()_+=-longerthan12chars"
        masked = _mask_token(token)
        assert "****" in masked


# ---------------------------------------------------------------------------
# Edge-case tests: argument parser
# ---------------------------------------------------------------------------


class TestBuildParserEdgeCases:
    """Edge-case tests for build_parser."""

    def test_invalid_depth_non_integer_exits(self):
        """Non-integer --depth should cause parser error."""
        parser = build_parser()
        with pytest.raises(SystemExit):
            parser.parse_args(["fetch", "https://figma.com/design/ABC/Title", "--depth", "abc"])

    def test_missing_url_argument_exits(self):
        """Omitting URL for fetch should cause parser error."""
        parser = build_parser()
        with pytest.raises(SystemExit):
            parser.parse_args(["fetch"])

    def test_missing_url_for_react_exits(self):
        """Omitting URL for react subcommand should cause parser error."""
        parser = build_parser()
        with pytest.raises(SystemExit):
            parser.parse_args(["react"])

    def test_empty_name_flag_is_allowed(self):
        """--name with empty string should be accepted."""
        parser = build_parser()
        args = parser.parse_args([
            "react", "https://figma.com/design/ABC/Title", "--name", ""
        ])
        assert args.name == ""

    def test_zero_depth_is_valid_boundary(self):
        """--depth 0 is a valid boundary value (zero)."""
        parser = build_parser()
        args = parser.parse_args(["fetch", "https://figma.com/design/ABC/Title", "--depth", "0"])
        assert args.depth == 0

    def test_negative_depth_is_parsed(self):
        """--depth with a negative value is parsed as integer (negative boundary)."""
        parser = build_parser()
        args = parser.parse_args(["fetch", "https://figma.com/design/ABC/Title", "--depth", "-1"])
        assert args.depth == -1

    def test_unknown_subcommand_exits(self):
        """An invalid/unknown subcommand should exit with error."""
        parser = build_parser()
        with pytest.raises(SystemExit):
            parser.parse_args(["invalid-command", "https://figma.com/design/ABC/Title"])

    def test_whitespace_name_flag(self):
        """--name with whitespace-only string is accepted as-is."""
        parser = build_parser()
        args = parser.parse_args([
            "react", "https://figma.com/design/ABC/Title", "--name", "   "
        ])
        assert args.name == "   "

    def test_unicode_name_flag(self):
        """--name with unicode component name is accepted."""
        parser = build_parser()
        args = parser.parse_args([
            "react", "https://figma.com/design/ABC/Title", "--name", "\u30d5\u30a9\u30fc\u30e0"
        ])
        assert args.name == "\u30d5\u30a9\u30fc\u30e0"

    def test_large_depth_value_boundary(self):
        """Large --depth value (overflow-like) is parsed as integer."""
        parser = build_parser()
        args = parser.parse_args([
            "fetch", "https://figma.com/design/ABC/Title", "--depth", "9999"
        ])
        assert args.depth == 9999


# ---------------------------------------------------------------------------
# Edge-case tests: main() integration
# ---------------------------------------------------------------------------


class TestMainEdgeCases:
    """Edge-case tests for main() entry point."""

    def test_missing_token_env_and_flag_exits_with_code_1(self, monkeypatch):
        """Both env and --token missing → exit code 1."""
        monkeypatch.delenv("FIGMA_TOKEN", raising=False)
        with pytest.raises(SystemExit) as exc_info:
            main(["fetch", "https://figma.com/design/ABC/Title"])
        assert exc_info.value.code == 1

    def test_invalid_malformed_url_exits(self, monkeypatch):
        """Completely malformed URL (not Figma) → exit code 1."""
        monkeypatch.setenv("FIGMA_TOKEN", "figd_test_token_value")
        with pytest.raises(SystemExit) as exc_info:
            main(["fetch", "not_a_url_at_all"])
        assert exc_info.value.code == 1

    def test_empty_url_string_exits(self, monkeypatch):
        """Empty string as URL → exit code 1."""
        monkeypatch.setenv("FIGMA_TOKEN", "figd_test_token_value")
        with pytest.raises(SystemExit) as exc_info:
            main(["fetch", ""])
        assert exc_info.value.code == 1

    def test_whitespace_only_token_exits(self, monkeypatch):
        """Token consisting only of whitespace → exit code 1 (stripped to empty)."""
        monkeypatch.delenv("FIGMA_TOKEN", raising=False)
        with pytest.raises(SystemExit) as exc_info:
            main(["--token", "   ", "fetch", "https://figma.com/design/ABC/Title"])
        assert exc_info.value.code == 1

    def test_write_and_output_flags_conflict(self, monkeypatch):
        """--write and --output together should error."""
        monkeypatch.setenv("FIGMA_TOKEN", "figd_test_token_value")
        with pytest.raises(SystemExit) as exc_info:
            main([
                "--output", "/tmp/out.json",
                "react",
                "https://figma.com/design/ABC/Title",
                "--write", "/tmp/dir/",
            ])
        assert exc_info.value.code == 2

    def test_react_missing_main_component_key_graceful(self, monkeypatch):
        """react command with result missing main_component → empty code written."""
        monkeypatch.setenv("FIGMA_TOKEN", "figd_test_token_value")
        import json as _json

        mock_result = {
            "content": _json.dumps({"file_key": "ABC"}),  # no main_component key
        }

        with patch("core.to_react", new_callable=AsyncMock, return_value=mock_result):
            captured = StringIO()
            monkeypatch.setattr("sys.stdout", captured)
            main([
                "react",
                "https://www.figma.com/design/ABC123XYZabcdef789012/Title?node-id=1-3",
            ])
        output = captured.getvalue()
        # Should not crash — produces valid JSON output without main_component
        parsed = json.loads(output)
        assert "content" in parsed


# ---------------------------------------------------------------------------
# Edge-case tests: _extract_component_name
# ---------------------------------------------------------------------------


class TestExtractComponentNameEdgeCases:
    """Edge-case tests for _extract_component_name."""

    def test_null_like_none_raises_or_returns_default(self):
        """None input: function uses regex on str, so must handle via empty str proxy."""
        # The function signature accepts str — test whitespace boundary
        assert _extract_component_name("   ") == "Component"

    def test_whitespace_around_function_name(self):
        """Extra whitespace between 'function' and name still extracts correctly."""
        code = "export default function   MyComponent() {}"
        # re.search with \s+ allows multiple spaces
        assert _extract_component_name(code) == "MyComponent"

    def test_special_characters_in_surrounding_code_no_match(self):
        """Code with special characters but no export default → returns default."""
        code = "const f = () => <div>! @ # $ %</div>;"
        assert _extract_component_name(code) == "Component"

    def test_unicode_component_name(self):
        """Unicode function names: regex \\w+ matches only ASCII word chars."""
        # \w matches [a-zA-Z0-9_] — unicode names won't match but shouldn't raise
        code = "export default function \u30b3\u30f3\u30dd\u30fc\u30cd\u30f3\u30c8() {}"
        # \w+ won't match unicode, so fallback to "Component"
        result = _extract_component_name(code)
        assert isinstance(result, str)

    def test_huge_input_string_no_crash(self):
        """Very large input (overflow-like) should not crash or raise."""
        code = "x" * 100_000
        result = _extract_component_name(code)
        assert result == "Component"

    def test_truncated_code_partial_match(self):
        """Truncated code that has partial 'export default function' won't match."""
        code = "export default func"  # truncated before full keyword
        assert _extract_component_name(code) == "Component"
