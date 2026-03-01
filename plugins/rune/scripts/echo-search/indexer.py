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

import hashlib
import os
import re
import sys

# Type aliases for Python 3.7 compat
from typing import Dict, List, Optional

VALID_ROLE_RE = re.compile(r'^[a-zA-Z0-9_-]+$')  # SEC-5: role name allowlist


def generate_id(role, line_number, file_path):
    """Generate a deterministic 16-char hex ID for an echo entry.

    The ID is a truncated SHA-256 hash of ``role:file_path:line_number``,
    ensuring stable identity across re-indexes.
    """
    # type: (str, int, str) -> str
    raw = "%s:%s:%d" % (role, file_path, line_number)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


def parse_memory_file(file_path, role):
    """Parse structured echo entries from a role-specific MEMORY.md file.

    Detects all 5 echo tiers (Inscribed, Etched, Traced, Notes, Observations)
    using stateful blank-line header detection (EDGE-018).

    Args:
        file_path: Absolute path to the MEMORY.md file.
        role: Role name (e.g., ``"reviewer"``, ``"planner"``).

    Returns:
        List of parsed entry dicts, each with a generated ``id`` field.
    """
    # type: (str, str) -> List[Dict]
    entries = []  # type: List[Dict]

    if not os.path.isfile(file_path):
        return entries

    with open(file_path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    # QUAL-008: Match all 5 echo tiers (Inscribed, Etched, Traced, Notes, Observations)
    header_re = re.compile(
        r"^##\s+(Inscribed|Etched|Traced|Notes|Observations)\s*[\u2014\-\u2013]+\s*(.+?)\s*\((\d{4}-\d{2}-\d{2})\)"
    )
    source_re = re.compile(r"^\*\*Source\*\*:\s*`?([^`\n]+)`?")

    current_entry = None  # type: Optional[Dict]
    content_lines = []  # type: List[str]
    # EDGE-018: Only match tier headers when previous line was blank (or start of file).
    # This prevents content H2 lines like "## Notes — inline note (2026-01-01)"
    # from being misinterpreted as new entry boundaries.
    prev_line_blank = True  # treat start-of-file as blank

    for i, line in enumerate(lines):
        line_num = i + 1  # 1-indexed
        stripped = line.rstrip("\n")

        # EDGE-018: Only attempt header match after a blank line
        header_match = header_re.match(stripped) if prev_line_blank else None
        if header_match:
            # Save previous entry
            if current_entry is not None:
                current_entry["content"] = "\n".join(content_lines).strip()
                if current_entry["content"]:
                    entries.append(current_entry)
                else:
                    print("WARN: empty entry at %s:%d — skipped" % (file_path, current_entry["line_number"]), file=sys.stderr)

            layer_name = header_match.group(1).lower()
            title = header_match.group(2).strip()
            date = header_match.group(3)

            current_entry = {
                "role": role,
                "layer": layer_name,
                "date": date,
                "source": "",
                "content": "",
                "tags": title,
                "line_number": line_num,
                "file_path": file_path,
            }
            content_lines = []
            continue

        if current_entry is not None:
            source_match = source_re.match(stripped)
            if source_match and not current_entry["source"]:
                current_entry["source"] = source_match.group(1).strip()
                continue

            content_lines.append(stripped)

        # EDGE-018: Track blank lines for stateful header detection
        prev_line_blank = stripped.strip() == ""

    # Flush last entry
    if current_entry is not None:
        current_entry["content"] = "\n".join(content_lines).strip()
        if current_entry["content"]:
            entries.append(current_entry)

    # Generate IDs
    for entry in entries:
        entry["id"] = generate_id(entry["role"], entry["line_number"], entry["file_path"])

    return entries


def discover_and_parse(echo_dir):
    """Walk the echoes directory and parse all role MEMORY.md files.

    Discovers ``<echo_dir>/<role>/MEMORY.md`` for each valid role
    subdirectory (SEC-5 allowlist) and returns a flat list of all entries.

    Args:
        echo_dir: Path to the ``.claude/echoes`` directory.

    Returns:
        Combined list of entry dicts across all roles.
    """
    # type: (str) -> List[Dict]
    all_entries = []  # type: List[Dict]

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
