#!/usr/bin/env python3
"""
Figma-to-React CLI

Primary interface for converting Figma designs to React + Tailwind CSS code.
Both humans and Claude Code agents use this same CLI.

Usage:
  python3 cli.py fetch URL [--depth N]
  python3 cli.py inspect URL
  python3 cli.py list URL
  python3 cli.py react URL [--name NAME] [--no-tailwind] [--extract] [--aria]
  python3 cli.py react URL --code                  # raw TSX to stdout
  python3 cli.py react URL --write ./components/   # write .tsx file
  python3 cli.py react URL --aria --code           # with ARIA attributes

Environment:
  FIGMA_TOKEN   Figma Personal Access Token (or use --token)
"""

from __future__ import annotations

import argparse
import asyncio
import json
import os
import re
import sys
import time
from pathlib import Path

# Import bootstrap — same pattern as tests/conftest.py.
# The directory is named "figma-to-react" (hyphenated — invalid Python package).
_PKG_DIR = Path(__file__).resolve().parent
if str(_PKG_DIR) not in sys.path:
    sys.path.insert(0, str(_PKG_DIR))

import core  # noqa: E402
from figma_client import FigmaAPIError, FigmaClient  # noqa: E402
from url_parser import FigmaURLError  # noqa: E402

# ---------------------------------------------------------------------------
# Terminal helpers
# ---------------------------------------------------------------------------


def _supports_color() -> bool:
    """Detect whether stderr supports ANSI colors."""
    if os.environ.get("NO_COLOR"):
        return False
    if os.environ.get("FORCE_COLOR"):
        return True
    return hasattr(sys.stderr, "isatty") and sys.stderr.isatty()


_COLOR = _supports_color()
_UTF8 = (getattr(sys.stderr, "encoding", "") or "").lower().startswith("utf")

ARROW = "\u2192" if _UTF8 else "->"
CHECK = "\u2713" if _UTF8 else "+"
CROSS = "\u2717" if _UTF8 else "x"


def _green(s: str) -> str:
    return f"\033[32m{s}\033[0m" if _COLOR else s


def _red(s: str) -> str:
    return f"\033[31m{s}\033[0m" if _COLOR else s


def _yellow(s: str) -> str:
    return f"\033[33m{s}\033[0m" if _COLOR else s


def _dim(s: str) -> str:
    return f"\033[2m{s}\033[0m" if _COLOR else s


def _verbose(msg: str, args: argparse.Namespace) -> None:
    """Print a verbose progress message to stderr."""
    if getattr(args, "verbose", False):
        print(f"  {ARROW} {msg}", file=sys.stderr)


# ---------------------------------------------------------------------------
# Token resolution
# ---------------------------------------------------------------------------


def _resolve_token(args: argparse.Namespace) -> Optional[str]:
    """Resolve Figma API token from --token flag or FIGMA_TOKEN env var.

    Returns None when no token is available, allowing Desktop MCP fallback.
    """
    token = getattr(args, "token", None) or os.environ.get("FIGMA_TOKEN", "")
    token = token.strip()  # Handle copy-paste trailing whitespace
    return token or None


def _mask_token(token: str) -> str:
    """Mask token for safe display: show first 5 + last 4 chars."""
    if len(token) <= 12:
        return "****"
    return f"{token[:5]}****{token[-4:]}"


# ---------------------------------------------------------------------------
# Subcommand handlers
# ---------------------------------------------------------------------------


async def _cmd_fetch(client: FigmaClient, args: argparse.Namespace) -> dict:
    """Handle the 'fetch' subcommand."""
    _verbose(f"Fetching design (depth={args.depth})...", args)
    result = await core.fetch_design(client, args.url, depth=args.depth)
    _verbose(f"{_green(CHECK)} Fetch complete", args)
    return result


async def _cmd_inspect(client: FigmaClient, args: argparse.Namespace) -> dict:
    """Handle the 'inspect' subcommand."""
    _verbose("Inspecting node properties...", args)
    result = await core.inspect_node(client, args.url)
    _verbose(f"{_green(CHECK)} Inspect complete", args)
    return result


async def _cmd_list(client: FigmaClient, args: argparse.Namespace) -> dict:
    """Handle the 'list' subcommand."""
    _verbose("Listing components...", args)
    result = await core.list_components(client, args.url)
    total = result.get("total_components", 0)
    instances = result.get("total_instances", 0)
    _verbose(
        f"{_green(CHECK)} Found {total} components, {instances} instances", args
    )
    return result


async def _cmd_react(client: FigmaClient, args: argparse.Namespace) -> dict:
    """Handle the 'react' subcommand."""
    _verbose("Generating React component...", args)
    result = await core.to_react(
        client,
        args.url,
        component_name=getattr(args, "name", "") or "",
        use_tailwind=not getattr(args, "no_tailwind", False),
        extract_components=getattr(args, "extract", False),
        aria=getattr(args, "aria", False),
    )
    _verbose(f"{_green(CHECK)} React generation complete", args)
    return result


# ---------------------------------------------------------------------------
# Argument parser
# ---------------------------------------------------------------------------


def _add_fetch_subparser(subparsers: argparse._SubParsersAction) -> None:
    """Register the 'fetch' subcommand."""
    p = subparsers.add_parser(
        "fetch", help="Fetch design and return IR tree",
        epilog="Example:\n  %(prog)s https://www.figma.com/design/ABC/Title --depth 3",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("url", help="Figma design URL")
    p.add_argument("--depth", type=int, default=2, help="API traversal depth (default: 2)")
    p.set_defaults(func=_cmd_fetch)


def _add_inspect_subparser(subparsers: argparse._SubParsersAction) -> None:
    """Register the 'inspect' subcommand."""
    p = subparsers.add_parser(
        "inspect", help="Inspect node properties (fills, strokes, layout, text)",
        epilog="Example:\n  %(prog)s https://www.figma.com/design/ABC/Title?node-id=1-3",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("url", help="Figma URL with ?node-id=... parameter")
    p.set_defaults(func=_cmd_inspect)


def _add_list_subparser(subparsers: argparse._SubParsersAction) -> None:
    """Register the 'list' subcommand."""
    p = subparsers.add_parser(
        "list", help="List all components in a Figma file",
        epilog="Example:\n  %(prog)s https://www.figma.com/design/ABC/Title",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("url", help="Figma file URL")
    p.set_defaults(func=_cmd_list)


def _add_react_subparser(subparsers: argparse._SubParsersAction) -> None:
    """Register the 'react' subcommand."""
    p = subparsers.add_parser(
        "react", help="Convert design to React + Tailwind CSS code",
        epilog="Example:\n  %(prog)s https://www.figma.com/design/ABC/Title?node-id=1-3 --name MyCard",
        formatter_class=argparse.RawDescriptionHelpFormatter,
    )
    p.add_argument("url", help="Figma URL (include ?node-id= for specific component)")
    p.add_argument("--name", default="", help="Override React component name")
    p.add_argument("--no-tailwind", action="store_true", help="Skip Tailwind CSS classes")
    p.add_argument("--extract", action="store_true", help="Extract repeated instances as components")
    p.add_argument("--aria", action="store_true", help="Add ARIA accessibility attributes to generated JSX")
    p.add_argument("--code", action="store_true", help="Print raw TSX code to stdout (no JSON wrapping)")
    p.add_argument("--write", metavar="PATH",
                   help="Write .tsx file directly (auto-names from component if PATH is a directory)")
    p.set_defaults(func=_cmd_react)


def build_parser() -> argparse.ArgumentParser:
    """Build the CLI argument parser with subcommands."""
    parser = argparse.ArgumentParser(
        prog="cli.py",
        description="Figma-to-React CLI — convert Figma designs to React components",
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog=(
            "Examples:\n"
            "  %(prog)s fetch https://www.figma.com/design/ABC/Title\n"
            "  %(prog)s react https://www.figma.com/design/ABC/Title?node-id=1-3 --pretty\n"
            "  %(prog)s list https://www.figma.com/design/ABC/Title --token figd_xxx\n"
        ),
    )
    parser.add_argument("--token", help="Figma API token (default: $FIGMA_TOKEN env var)")
    parser.add_argument("--pretty", action="store_true", help="Pretty-print JSON output with indentation")
    parser.add_argument("--output", "-o", metavar="FILE", help="Write output to file instead of stdout")
    parser.add_argument("--verbose", "-v", action="store_true", help="Show progress messages on stderr")

    subs = parser.add_subparsers(dest="command", required=True, metavar="{fetch,inspect,list,react}")
    _add_fetch_subparser(subs)
    _add_inspect_subparser(subs)
    _add_list_subparser(subs)
    _add_react_subparser(subs)
    return parser


# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------


def _extract_component_name(code: str) -> str:
    """Extract the React component name from generated code.

    Looks for 'export default function Name' which is the pattern
    used by react_generator.py.
    """
    match = re.search(r"export default function\s+(\w+)", code)
    return match.group(1) if match else "Component"


async def _run(args: argparse.Namespace) -> str:
    """Execute the subcommand and return output string.

    Returns raw TSX code when --code or --write is active,
    otherwise returns JSON.
    """
    token = _resolve_token(args)
    if token:
        _verbose(f"Using token: {_dim(_mask_token(token))}", args)

    # FigmaClient reads FIGMA_TOKEN from env — set before construction.
    old_token = os.environ.get("FIGMA_TOKEN")
    if token:
        os.environ["FIGMA_TOKEN"] = token

    t0 = time.monotonic()
    client = None
    try:
        client = FigmaClient()
        result = await args.func(client, args)
        elapsed = time.monotonic() - t0
        _verbose(f"Done ({elapsed:.1f}s)", args)

        # --code / --write: extract raw React code instead of JSON
        if getattr(args, "code", False) or getattr(args, "write", None):
            return core.extract_react_code(result)

        return json.dumps(result, indent=2 if args.pretty else None, ensure_ascii=False)
    finally:
        if client is not None:
            await client.close()
        if old_token is None:
            os.environ.pop("FIGMA_TOKEN", None)
        else:
            os.environ["FIGMA_TOKEN"] = old_token


def _emit_output(output: str, args: argparse.Namespace) -> None:
    """Write output to the appropriate destination (file, --write path, or stdout)."""
    use_write = getattr(args, "write", None)
    if use_write:
        write_path = Path(use_write)
        if write_path.is_dir() or write_path.suffix not in (".tsx", ".jsx", ".ts", ".js"):
            write_path = write_path / f"{_extract_component_name(output)}.tsx"
        write_path = write_path.resolve()
        write_path.parent.mkdir(parents=True, exist_ok=True)
        write_path.write_text(output, encoding="utf-8")
        print(f"  {_green(CHECK)} Written to {write_path}", file=sys.stderr)
    elif args.output:
        out_path = Path(args.output).resolve()
        out_path.write_text(output, encoding="utf-8")
        if args.verbose:
            print(f"  {ARROW} Written to {out_path}", file=sys.stderr)
    else:
        print(output)


def main(argv: list[str] | None = None) -> None:
    """CLI entry point."""
    parser = build_parser()
    args = parser.parse_args(argv)

    # Validate mutually exclusive output flags
    use_code = getattr(args, "code", False)
    use_write = getattr(args, "write", None)
    if use_code and use_write:
        parser.error("--code and --write are mutually exclusive")
    if (use_code or use_write) and args.output:
        parser.error("--code/--write cannot be combined with --output")

    try:
        output = asyncio.run(_run(args))
    except KeyboardInterrupt:
        print(f"\n{_yellow('Interrupted.')}", file=sys.stderr)
        sys.exit(130)  # POSIX: 128 + SIGINT(2)
    except FigmaURLError as exc:
        print(_red(f"{CROSS} URL error: {exc}"), file=sys.stderr)
        sys.exit(1)
    except FigmaAPIError as exc:
        print(_red(f"{CROSS} API error: {exc}"), file=sys.stderr)
        sys.exit(2)
    except (RuntimeError, IOError, ValueError, TypeError) as exc:
        print(_red(f"{CROSS} Error: {exc}"), file=sys.stderr)
        sys.exit(3)

    _emit_output(output, args)


if __name__ == "__main__":
    main()
