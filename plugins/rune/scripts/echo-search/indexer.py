"""
MEMORY.md parser for the Echo Search MCP server.

Parses structured echo entries from role-specific MEMORY.md files
within the .rune/echoes/ directory.

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
ALLOWED_DOMAINS = frozenset({
    "backend", "frontend", "devops", "database",
    "testing", "architecture", "design", "general",
})

MAX_PACK_SIZE_MB = 10  # SEC-P2-005: reject files larger than this
MAX_LINES = 10000  # SEC-P2-005: truncate files beyond this line count


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
_DOMAIN_RE = re.compile(r"^\*\*Domain\*\*:\s*(.+)")


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
        "domain": "general",
        "content": "",
        "tags": header_match.group(2).strip(),
        "line_number": line_num,
        "file_path": file_path,
    }


def _valid_subdirs(parent: str, *, seen_inodes: set[int] | None = None) -> list[str]:
    """Return valid subdirectories with symlink loop and containment protection.

    Applies SEC-5 role name allowlist, realpath containment check (SEC-P2-003),
    and inode-based cycle detection (D-P2-003).
    """
    if seen_inodes is None:
        seen_inodes = set()

    result: list[str] = []
    real_parent = os.path.realpath(parent)

    if not os.path.isdir(real_parent):
        return result

    for name in sorted(os.listdir(real_parent)):
        if not VALID_ROLE_RE.match(name):  # SEC-5
            continue
        child = os.path.join(parent, name)
        real_child = os.path.realpath(child)

        # SEC-P2-003: containment check — child must be under parent
        if not real_child.startswith(real_parent + os.sep):
            print("WARN: symlink escape detected: %s -> %s" % (child, real_child), file=sys.stderr)
            continue

        # D-P2-003: inode cycle detection
        try:
            inode = os.stat(real_child).st_ino
        except OSError:
            continue
        if inode in seen_inodes:
            print("WARN: inode cycle detected at %s (inode %d)" % (child, inode), file=sys.stderr)
            continue
        seen_inodes.add(inode)

        if os.path.isdir(real_child):
            result.append(child)

    return result


def _check_file_size(file_path: str) -> bool:
    """Check file size against SEC-P2-005 limits.

    Returns True if the file is within acceptable size limits.
    """
    try:
        size_bytes = os.path.getsize(file_path)
    except OSError:
        return False
    max_bytes = MAX_PACK_SIZE_MB * 1024 * 1024
    if size_bytes > max_bytes:
        print("WARN: file too large (%d bytes > %d MB limit): %s" % (
            size_bytes, MAX_PACK_SIZE_MB, file_path), file=sys.stderr)
        return False
    return True


def _parse_entry_metadata(
    stripped: str, current_entry: dict, file_path: str, line_num: int,
) -> bool:
    """Parse metadata lines (Source, Category, Domain) from an entry.

    Attempts to match the line against Source, Category, and Domain
    patterns. Mutates ``current_entry`` in place when a match is found.

    Args:
        stripped: Stripped line text.
        current_entry: Entry dict to update.
        file_path: File path for warning messages.
        line_num: 1-based line number for warning messages.

    Returns:
        True if the line was consumed as metadata, False otherwise.
    """
    source_match = _SOURCE_RE.match(stripped)
    if source_match and not current_entry["source"]:
        current_entry["source"] = source_match.group(1).strip()
        return True
    # QUAL-100: Parse **Category**: and **Domain**: outside in_metadata guard
    # so doc pack entries (and entries with varied formatting) are parsed
    # robustly. Guard with "only if still at default" to prevent re-parsing
    # once explicitly set — preserving BACK-007 intent (first match wins).
    category_match = _CATEGORY_RE.match(stripped)
    if category_match and current_entry["category"] == "general":
        raw_category = category_match.group(1).strip().lower()
        if raw_category in ALLOWED_CATEGORIES:
            current_entry["category"] = raw_category
        else:
            print("WARN: unknown category '%s' at %s:%d, defaulting to 'general'" % (
                raw_category, file_path, line_num), file=sys.stderr)
            current_entry["category"] = "general"
        return True
    domain_match = _DOMAIN_RE.match(stripped)
    if domain_match and current_entry["domain"] == "general":
        raw_domain = domain_match.group(1).strip().lower()
        if raw_domain in ALLOWED_DOMAINS:
            current_entry["domain"] = raw_domain
        else:
            print("WARN: unknown domain '%s' at %s:%d, defaulting to 'general'" % (
                raw_domain, file_path, line_num), file=sys.stderr)
        return True
    return False


def _extract_entries_from_sections(
    lines: list[str], role: str, file_path: str,
) -> list[dict]:
    """Extract entry dicts from parsed MEMORY.md lines.

    Iterates through lines, detecting entry headers and collecting
    metadata and content for each entry section.

    Args:
        lines: Raw file lines (with newlines).
        role: Role name for entry attribution.
        file_path: Source file path.

    Returns:
        List of entry dicts (without IDs — caller assigns those).
    """
    entries: list[dict] = []
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
            if _parse_entry_metadata(stripped, current_entry, file_path, i + 1):
                continue
            if in_metadata:
                # First non-blank, non-source, non-category, non-domain line → end metadata
                if stripped.strip() and not stripped.startswith("**"):
                    in_metadata = False
            content_lines.append(stripped)
        prev_line_blank = stripped.strip() == ""

    _flush_entry(current_entry, content_lines, entries, file_path)
    return entries


def parse_memory_file(file_path: str, role: str) -> list[dict]:
    """Parse structured echo entries from a role-specific MEMORY.md file."""
    if not os.path.isfile(file_path):
        return []

    try:
        with open(file_path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except UnicodeDecodeError:
        print("WARN: skipping binary/corrupted file: %s" % file_path, file=sys.stderr)
        return []

    # SEC-P2-005: truncate beyond MAX_LINES
    if len(lines) > MAX_LINES:
        print("WARN: truncating %s at %d lines (max %d)" % (file_path, len(lines), MAX_LINES), file=sys.stderr)
        lines = lines[:MAX_LINES]

    entries = _extract_entries_from_sections(lines, role, file_path)

    for entry in entries:
        entry["id"] = generate_id(entry["role"], entry["line_number"], entry["file_path"])
    return entries


def discover_and_parse(echo_dir: str) -> list[dict]:
    """Walk the echoes directory and parse all role MEMORY.md files.

    Discovers ``<echo_dir>/<role>/MEMORY.md`` for each valid role
    subdirectory (SEC-5 allowlist) and returns a flat list of all entries.
    Also discovers doc packs at ``<echo_dir>/doc-packs/<pack-name>/MEMORY.md``.

    Args:
        echo_dir: Path to the ``.rune/echoes`` directory.

    Returns:
        Combined list of entry dicts across all roles.
    """
    all_entries: list[dict] = []

    if not os.path.isdir(echo_dir):
        return all_entries

    seen_inodes: set[int] = set()

    # Existing: walk <echo_dir>/<role>/MEMORY.md
    for role_path in _valid_subdirs(echo_dir, seen_inodes=seen_inodes):
        role_name = os.path.basename(role_path)
        if role_name == "doc-packs":
            continue  # handled separately below
        memory_file = os.path.join(role_path, "MEMORY.md")
        if os.path.isfile(memory_file) and _check_file_size(memory_file):
            entries = parse_memory_file(memory_file, role_name)
            all_entries.extend(entries)

    # NEW: walk <echo_dir>/doc-packs/<pack-name>/MEMORY.md
    doc_packs_dir = os.path.join(echo_dir, "doc-packs")
    if os.path.isdir(doc_packs_dir):
        for pack_path in _valid_subdirs(doc_packs_dir, seen_inodes=seen_inodes):
            pack_name = os.path.basename(pack_path)
            # D-P2-006: prefix doc-pack roles to avoid collision with project roles
            # SEC-004: use -- separator (not /) to match VALID_ROLE_RE / _SAFE_ROLE_RE
            role = "doc-pack--%s" % pack_name
            memory_file = os.path.join(pack_path, "MEMORY.md")
            if os.path.isfile(memory_file) and _check_file_size(memory_file):
                entries = parse_memory_file(memory_file, role)
                all_entries.extend(entries)

    return all_entries
