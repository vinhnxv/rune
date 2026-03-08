"""
MEMORY.md parser for the Echo Search MCP server.

Parses structured echo entries from role-specific MEMORY.md files
within the .claude/echoes/ directory.

Expected format:
    ## Inscribed - Title here (YYYY-MM-DD)
    **Source**: `rune:appraise session-abc`
    **Confidence**: HIGH (...)
    ### Section heading
    - Content describing the learning
"""

from __future__ import annotations

import hashlib
import os
import re
import sys

VALID_ROLE_RE = re.compile(r'^[a-zA-Z0-9_-]+$')  # SEC-5: role name allowlist
ALLOWED_CATEGORIES = {"pattern", "anti-pattern", "decision", "debugging", "general"}
VALID_LAYERS = frozenset({"etched", "notes", "inscribed", "observations", "traced"})


def generate_id(role: str, line_number: int, file_path: str) -> str:
    """Generate a deterministic 16-char hex ID for an echo entry.

    The ID is a truncated SHA-256 hash of ``role:file_path:line_number``,
    ensuring stable identity across re-indexes.
    """
    raw = "%s:%s:%d" % (role, file_path, line_number)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


# Layer alternation built from VALID_LAYERS for single-source-of-truth (QUAL-007)
_LAYER_ALT = "|".join(l.capitalize() for l in sorted(VALID_LAYERS))
_HEADER_RE = re.compile(
    r"^##\s+(%s)\s*[\u2014\-\u2013]+\s*(.+?)\s*\((\d{4}-\d{2}-\d{2})\)" % _LAYER_ALT
)
_SOURCE_RE = re.compile(r"^\*\*Source\*\*:\s*`?([^`\n]+)`?")
_CATEGORY_RE = re.compile(r"^\*\*Category\*\*:\s*(\S+)")


def _flush_entry(current_entry: dict | None, content_lines: list[str], entries: list[dict], file_path: str) -> None:
    """Flush a completed entry into the entries list."""
    if current_entry is None:
        return
    current_entry["content"] = "\n".join(content_lines).strip()
    if current_entry["content"]:
        entries.append(current_entry)
    else:
        print("WARN: empty entry at %s:%d — skipped" % (file_path, current_entry["line_number"]), file=sys.stderr)


def _make_entry(role: str, header_match: re.Match, line_num: int, file_path: str) -> dict:
    """Create a new entry dict from a header match."""
    return {
        "role": role,
        "layer": header_match.group(1).lower(),
        "date": header_match.group(3),
        "source": "",
        "category": "general",
        "content": "",
        "tags": header_match.group(2).strip(),
        "line_number": line_num,
        "file_path": file_path,
    }


def parse_memory_file(file_path: str, role: str) -> list[dict]:
    """Parse structured echo entries from a role-specific MEMORY.md file."""
    entries: list[dict] = []
    if not os.path.isfile(file_path):
        return entries

    try:
        with open(file_path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except UnicodeDecodeError:
        print("WARN: skipping binary/corrupted file: %s" % file_path, file=sys.stderr)
        return entries

    current_entry: dict | None = None
    content_lines: list[str] = []
    in_metadata = False
    prev_line_blank = True  # EDGE-018: treat start-of-file as blank

    for i, line in enumerate(lines):
        stripped = line.rstrip("\n")
        header_match = _HEADER_RE.match(stripped) if prev_line_blank else None
        if header_match:
            _flush_entry(current_entry, content_lines, entries, file_path)
            current_entry = _make_entry(role, header_match, i + 1, file_path)
            content_lines = []
            in_metadata = True
            prev_line_blank = True  # allow consecutive headers (next header can follow)
            continue
        if current_entry is not None:
            source_match = _SOURCE_RE.match(stripped)
            if source_match and not current_entry["source"]:
                current_entry["source"] = source_match.group(1).strip()
                continue  # source lines don't affect blank-line tracking
            # Only parse category in metadata section (before first ### or content).
            # BACK-007: **Category**: must appear before the first non-metadata content
            # line (i.e., before any heading or body text). Category lines after content
            # starts will be treated as regular content, not metadata.
            if in_metadata:
                category_match = _CATEGORY_RE.match(stripped)
                if category_match:
                    raw_category = category_match.group(1).strip().lower()
                    if raw_category in ALLOWED_CATEGORIES:
                        current_entry["category"] = raw_category
                    else:
                        print("WARN: unknown category '%s' at %s:%d, defaulting to 'general'" % (
                            raw_category, file_path, i + 1), file=sys.stderr)
                        current_entry["category"] = "general"
                    continue
                # First non-blank, non-source, non-category line → end metadata
                if stripped.strip() and not stripped.startswith("**"):
                    in_metadata = False
            content_lines.append(stripped)
        prev_line_blank = stripped.strip() == ""

    _flush_entry(current_entry, content_lines, entries, file_path)

    for entry in entries:
        entry["id"] = generate_id(entry["role"], entry["line_number"], entry["file_path"])
    return entries


def discover_and_parse(echo_dir: str) -> list[dict]:
    """Walk the echoes directory and parse all role MEMORY.md files.

    Discovers ``<echo_dir>/<role>/MEMORY.md`` for each valid role
    subdirectory (SEC-5 allowlist) and returns a flat list of all entries.

    Args:
        echo_dir: Path to the ``.claude/echoes`` directory.

    Returns:
        Combined list of entry dicts across all roles.
    """
    all_entries: list[dict] = []

    if not os.path.isdir(echo_dir):
        return all_entries

    for role_name in sorted(os.listdir(echo_dir)):
        if not VALID_ROLE_RE.match(role_name):  # SEC-5: skip unexpected dir names
            continue
        role_path = os.path.join(echo_dir, role_name)
        if not os.path.isdir(role_path):
            continue

        memory_file = os.path.join(role_path, "MEMORY.md")
        if os.path.isfile(memory_file):
            entries = parse_memory_file(memory_file, role_name)
            all_entries.extend(entries)

    return all_entries
