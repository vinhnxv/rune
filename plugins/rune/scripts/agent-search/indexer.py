"""
Agent definition parser for the Agent Search MCP server.

Parses YAML frontmatter from agent .md files across 6 source directories:
  - agents/              (builtin, priority 100)
  - registry/            (extended, priority 80)
  - .claude/agents/      (project, priority 75)
  - .rune/rune-agents/   (rune-project, priority 70) — search-only, not auto-loaded
  - extra_agent_dirs     (external, priority 60)
  - talisman user_agents (user, priority 50)

Expected format:
    ---
    name: flaw-hunter
    description: |
      Logic bug detection through edge case analysis...
    tools:
      - Read
      - Glob
    model: sonnet
    maxTurns: 30
    ---
    # Agent body markdown...
"""

from __future__ import annotations

import hashlib
import os
import re
import sys
from typing import Any, Dict, List, Optional, Tuple

from schema import VALID_CATEGORIES, VALID_NAME_RE

# YAML frontmatter boundary
_FRONTMATTER_RE = re.compile(r'^---\s*$')

# Standard phases for agent phase mapping
STANDARD_PHASES = frozenset({
    "devise", "forge", "appraise", "audit", "strive",
    "arc", "mend", "inspect", "goldmask", "debug",
    "test-browser", "design-sync", "design-prototype",
})

# Source priority mapping
SOURCE_PRIORITIES = {
    "builtin": 100,
    "extended": 80,
    "project": 75,
    "rune-project": 70,
    "external": 60,
    "user": 50,
}

MAX_FILE_SIZE_MB = 5  # SEC-P2-005: reject agent files larger than this
MAX_LINES = 5000  # SEC-P2-005: truncate files beyond this line count


def generate_id(name: str, source: str, file_path: str) -> str:
    """Generate a deterministic 16-char hex ID for an agent entry.

    The ID is a truncated SHA-256 hash of ``name:source:file_path``,
    ensuring stable identity across re-indexes.

    Args:
        name: Agent name.
        source: Source category (builtin, extended, project, user).
        file_path: Absolute path to the agent definition file.

    Returns:
        16-character hex string.
    """
    raw = "%s:%s:%s" % (name, source, file_path)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


def _check_file_size(file_path: str) -> bool:
    """Check file size against SEC-P2-005 limits.

    Returns True if the file is within acceptable size limits.
    """
    try:
        size_bytes = os.path.getsize(file_path)
    except OSError:
        return False
    max_bytes = MAX_FILE_SIZE_MB * 1024 * 1024
    if size_bytes > max_bytes:
        print("WARN: agent file too large (%d bytes > %d MB limit): %s" % (
            size_bytes, MAX_FILE_SIZE_MB, file_path), file=sys.stderr)
        return False
    return True


def _parse_yaml_value(key: str, value: str) -> Tuple[str, Any]:
    """Parse a YAML scalar value, handling quotes, booleans, and numbers.

    Returns (key, parsed_value).
    """
    # FLAW-014 FIX: Strip surrounding quotes from YAML scalar values
    if (value.startswith('"') and value.endswith('"')) or \
       (value.startswith("'") and value.endswith("'")):
        value = value[1:-1]
    # Parse booleans and numbers
    if value.lower() in ("true", "yes"):
        return key, True
    elif value.lower() in ("false", "no"):
        return key, False
    else:
        try:
            return key, int(value)
        except ValueError:
            return key, value


def _flush_pending_state(
    metadata: Dict[str, Any],
    current_key: Optional[str],
    current_list: Optional[List[str]],
    current_multiline: Optional[List[str]],
) -> None:
    """Flush any pending list or multiline value into metadata."""
    if current_key and current_list is not None:
        metadata[current_key] = current_list
    elif current_key and current_multiline is not None:
        metadata[current_key] = "\n".join(current_multiline).strip()


def _try_list_continuation(
    stripped: str,
    current_key: Optional[str],
    current_list: Optional[List[str]],
) -> bool:
    """Try to parse a list item continuation line. Returns True if consumed."""
    if not (stripped.startswith("  - ") or stripped.startswith("  -\t")):
        return False
    if not (current_key and current_list is not None):
        return False
    item = stripped.strip()
    # Fix: remove only the first "- " prefix, not all leading dashes
    if item.startswith("- "):
        item = item[2:]
    elif item.startswith("-"):
        item = item[1:]
    current_list.append(item.strip())
    return True


def _try_multiline_continuation(
    stripped: str,
    metadata: Dict[str, Any],
    current_key: Optional[str],
    current_list: Optional[List[str]],
    current_multiline: Optional[List[str]],
) -> Tuple[bool, Optional[str], Optional[List[str]]]:
    """Try multiline string continuation. Returns (consumed, updated_key, updated_multiline)."""
    if not (current_key and current_multiline is not None):
        return False, current_key, current_multiline
    if stripped.startswith("  ") or stripped == "":
        current_multiline.append(stripped.strip())
        return True, current_key, current_multiline
    # End of multiline — flush and fall through
    _flush_pending_state(metadata, current_key, current_list, current_multiline)
    return False, None, None


def _parse_new_key_value(
    stripped: str,
    metadata: Dict[str, Any],
) -> Tuple[Optional[str], Optional[List[str]], Optional[List[str]]]:
    """Parse a new key:value line. Returns (current_key, current_list, current_multiline)."""
    colon_pos = stripped.find(":")
    if colon_pos <= 0:
        return None, None, None
    key = stripped[:colon_pos].strip()
    value = stripped[colon_pos + 1:].strip()
    if value == "|":
        return key, None, []
    elif value == "":
        return key, [], None
    else:
        _, parsed = _parse_yaml_value(key, value)
        metadata[key] = parsed
        return None, None, None


def _parse_frontmatter(lines: List[str]) -> Tuple[Dict[str, Any], int]:
    """Parse YAML frontmatter from lines, returning (metadata, body_start_line).

    Line-based parser (no PyYAML). Handles scalars, lists (- item), and
    multi-line strings (|). Returns ({}, 0) if no valid frontmatter found.
    """
    if not lines or not _FRONTMATTER_RE.match(lines[0]):
        return {}, 0

    metadata: Dict[str, Any] = {}
    ck: Optional[str] = None
    cl: Optional[List[str]] = None
    cm: Optional[List[str]] = None
    body_start = len(lines)

    for i, line in enumerate(lines[1:], start=1):
        if _FRONTMATTER_RE.match(line):
            _flush_pending_state(metadata, ck, cl, cm)
            body_start = i + 1
            break
        stripped = line.rstrip()
        if _try_list_continuation(stripped, ck, cl):
            continue
        consumed, ck, cm = _try_multiline_continuation(stripped, metadata, ck, cl, cm)
        if consumed:
            continue
        if ck and cl is not None:
            _flush_pending_state(metadata, ck, cl, cm)
            ck, cl = None, None
        ck, cl, cm = _parse_new_key_value(stripped, metadata)

    _flush_pending_state(metadata, ck, cl, cm)

    # Fix BACK-003: Detect unclosed frontmatter (no closing ---)
    if body_start == len(lines) and len(metadata) > 0:
        print("WARN: unclosed frontmatter (no closing ---) in file — treating as invalid", file=sys.stderr)
        return {}, 0

    return metadata, body_start


def _infer_category(file_path: str, metadata: Dict[str, Any]) -> str:
    """Infer agent category from file path or metadata.

    Checks the parent directory name first (e.g., agents/review/foo.md -> review),
    then falls back to explicit metadata, then "unknown".

    Args:
        file_path: Path to the agent file.
        metadata: Parsed frontmatter metadata.

    Returns:
        Category string from VALID_CATEGORIES, or "unknown".
    """
    # Check parent directory
    parent_dir = os.path.basename(os.path.dirname(file_path))
    if parent_dir in VALID_CATEGORIES:
        return parent_dir

    # Check metadata
    category = metadata.get("category", "")
    if isinstance(category, str) and category.lower() in VALID_CATEGORIES:
        return category.lower()

    return "unknown"


def _infer_phases(metadata: Dict[str, Any], category: str) -> List[str]:
    """Infer compatible phases from metadata or category defaults.

    Args:
        metadata: Parsed frontmatter metadata.
        category: Agent category.

    Returns:
        List of phase names.
    """
    # Explicit phases in metadata
    phases = metadata.get("phases", [])
    if isinstance(phases, list) and phases:
        return [p for p in phases if isinstance(p, str) and p in STANDARD_PHASES]

    # Default phase mapping by category
    defaults = {
        "review": ["appraise", "audit", "arc"],
        "investigation": ["goldmask", "inspect", "arc"],
        "research": ["devise", "forge", "arc"],
        "work": ["strive", "arc", "mend"],
        "utility": ["devise", "arc", "mend", "forge"],
        "testing": ["arc", "strive"],
    }
    return defaults.get(category, [])


def _extract_tags(metadata: Dict[str, Any], body: str) -> List[str]:
    """Extract searchable tags from metadata and body content.

    Combines explicit tags, tool names, and keywords extracted from the
    description.

    Args:
        metadata: Parsed frontmatter metadata.
        body: Agent body markdown text.

    Returns:
        Deduplicated list of tag strings.
    """
    tags: List[str] = []

    # Explicit tags
    explicit = metadata.get("tags", [])
    if isinstance(explicit, list):
        tags.extend(str(t) for t in explicit if t)
    elif isinstance(explicit, str):
        tags.extend(t.strip() for t in explicit.split(",") if t.strip())

    # Tools as tags
    tools = metadata.get("tools", [])
    if isinstance(tools, list):
        tags.extend("tool:%s" % str(t).lower() for t in tools if t)

    # Keywords from description
    desc = metadata.get("description", "")
    if isinstance(desc, str):
        # Extract notable keywords (capitalized terms, technical terms)
        words = re.findall(r'\b[A-Z][a-z]+(?:\s+[A-Z][a-z]+)*\b', desc)
        tags.extend(w.lower() for w in words[:10])
        # Also capture ALL-CAPS acronyms (SQL, FTS5, OWASP, JWT, API, etc.)
        acronyms = re.findall(r'\b[A-Z0-9]{2,}(?:-[A-Z0-9]+)*\b', desc)
        tags.extend(a.lower() for a in acronyms[:5])

    # MCP servers as tags
    mcp = metadata.get("mcpServers", [])
    if isinstance(mcp, list):
        tags.extend("mcp:%s" % str(s) for s in mcp if s)

    # Deduplicate preserving order
    seen: set = set()
    unique: List[str] = []
    for t in tags:
        if t not in seen:
            seen.add(t)
            unique.append(t)
    return unique


def _read_agent_lines(file_path: str) -> Optional[List[str]]:
    """Read and validate an agent file, returning stripped lines or None on failure."""
    if not os.path.isfile(file_path):
        return None
    if not _check_file_size(file_path):
        return None
    try:
        with open(file_path, "r", encoding="utf-8") as f:
            lines = f.readlines()
    except (UnicodeDecodeError, OSError) as exc:
        print("WARN: skipping unreadable agent file: %s (%s)" % (file_path, exc),
              file=sys.stderr)
        return None
    # SEC-P2-005: truncate beyond MAX_LINES
    if len(lines) > MAX_LINES:
        print("WARN: truncating %s at %d lines (max %d)" % (
            file_path, len(lines), MAX_LINES), file=sys.stderr)
        lines = lines[:MAX_LINES]
    return [l.rstrip("\n") for l in lines]


def _derive_agent_name(
    metadata: Dict[str, Any], file_path: str,
) -> Optional[str]:
    """Derive and validate agent name from metadata or filename. Returns None if invalid."""
    name = metadata.get("name", "")
    if not isinstance(name, str) or not name:
        name = os.path.splitext(os.path.basename(file_path))[0]
    if not VALID_NAME_RE.match(name):
        print("WARN: invalid agent name '%s' in %s — skipped" % (name, file_path),
              file=sys.stderr)
        return None
    return name


def _extract_languages(metadata: Dict[str, Any]) -> List[str]:
    """Extract and normalize languages from frontmatter metadata."""
    languages_raw = metadata.get("languages", [])
    if isinstance(languages_raw, str):
        languages_raw = [languages_raw]
    # SEC-WARD-003 FIX: Truncate per-value to 50 chars, cap list at 20 items
    return [lang.strip().lower()[:50] for lang in languages_raw
            if isinstance(lang, str) and lang.strip()][:20]


def _build_agent_entry(
    name: str, source: str, file_path: str,
    metadata: Dict[str, Any], body: str,
    category: str, phases: List[str], tags: List[str],
    languages: List[str],
) -> Dict[str, Any]:
    """Build the agent entry dict from parsed components."""
    description = metadata.get("description", "")
    if not isinstance(description, str):
        description = str(description)
    return {
        "id": generate_id(name, source, file_path),
        "name": name,
        "description": description,
        "category": category,
        "primary_phase": phases[0] if phases else "",
        "compatible_phases": phases,
        "tags": tags,
        "source": source,
        "priority": SOURCE_PRIORITIES.get(source, 50),
        "languages": languages,
        "tools": metadata.get("tools", []),
        "model": metadata.get("model", ""),
        "max_turns": metadata.get("maxTurns", 0),
        "body": body,
        "file_path": file_path,
        "metadata": metadata,
    }


def parse_agent_file(
    file_path: str,
    source: str,
) -> Optional[Dict[str, Any]]:
    """Parse a single agent .md file into a structured entry dict.

    Args:
        file_path: Absolute path to the agent .md file.
        source: Source category (builtin, extended, project, user).

    Returns:
        Entry dict with all agent fields, or None if parsing fails.
    """
    stripped_lines = _read_agent_lines(file_path)
    if stripped_lines is None:
        return None

    metadata, body_start = _parse_frontmatter(stripped_lines)
    if not metadata:
        print("WARN: no frontmatter in agent file: %s" % file_path, file=sys.stderr)
        return None

    name = _derive_agent_name(metadata, file_path)
    if name is None:
        return None

    category = _infer_category(file_path, metadata)
    phases = _infer_phases(metadata, category)
    body = "\n".join(stripped_lines[body_start:]).strip()
    tags = _extract_tags(metadata, body)
    languages = _extract_languages(metadata)

    return _build_agent_entry(
        name, source, file_path, metadata, body,
        category, phases, tags, languages,
    )


def _valid_agent_files(directory: str) -> List[str]:
    """Find all .md files in a directory (non-recursive for flat dirs, recursive for categorized).

    Applies SEC-5 name allowlist and symlink containment checks.

    Args:
        directory: Path to scan for agent .md files.

    Returns:
        List of absolute paths to valid agent .md files.
    """
    results: List[str] = []
    if not os.path.isdir(directory):
        return results

    real_parent = os.path.realpath(directory)

    for root, dirs, files in os.walk(real_parent):
        # SEC-P2-003: containment check
        # SEC-001 FIX: Add os.sep to prevent prefix-collision bypass (e.g. /project-evil
        # would pass startswith("/project") without the separator check).
        real_root = os.path.realpath(root)
        if not (real_root.startswith(real_parent + os.sep) or real_root == real_parent):
            continue

        # Skip hidden dirs and reference dirs
        dirs[:] = [d for d in dirs
                   if not d.startswith(".")
                   and d != "references"
                   and VALID_NAME_RE.match(d)]

        for fname in sorted(files):
            if not fname.endswith(".md"):
                continue
            # Skip reference/support files
            if fname.startswith("_") or fname == "README.md":
                continue
            fpath = os.path.join(root, fname)
            # SEC-P2-003: containment check
            # SEC-001 FIX: Add os.sep guard against prefix-collision bypass.
            real_fpath = os.path.realpath(fpath)
            if real_fpath.startswith(real_parent + os.sep) or real_fpath == real_parent:
                results.append(fpath)

    return results


def _scan_standard_sources(
    plugin_root: str,
    project_dir: str,
) -> List[Dict[str, Any]]:
    """Scan the 4 standard agent source directories.

    Sources (in priority order):
      1. agents/              (builtin, p100)
      2. registry/            (extended, p80)
      3. .claude/agents/      (project, p75)
      4. .rune/rune-agents/   (rune-project, p70)
    """
    entries: List[Dict[str, Any]] = []

    source_dirs = [
        (os.path.join(plugin_root, "agents"), "builtin"),
        (os.path.join(plugin_root, "registry"), "extended"),
        (os.path.join(project_dir, ".claude", "agents"), "project"),
        (os.path.join(project_dir, ".rune", "rune-agents"), "rune-project"),
    ]

    for dir_path, source in source_dirs:
        for fpath in _valid_agent_files(dir_path):
            entry = parse_agent_file(fpath, source)
            if entry:
                entries.append(entry)

    return entries


def _scan_extra_dirs(
    extra_agent_dirs: Optional[List[str]],
    project_dir: str,
) -> List[Dict[str, Any]]:
    """Scan extra agent directories from talisman config with containment checks."""
    entries: List[Dict[str, Any]] = []

    if not extra_agent_dirs or not isinstance(extra_agent_dirs, list):
        return entries

    for extra_dir in extra_agent_dirs:
        if not isinstance(extra_dir, str) or not extra_dir:
            continue
        # Resolve relative paths against project_dir
        if not os.path.isabs(extra_dir):
            extra_dir = os.path.join(project_dir, extra_dir)
        # SEC: containment — skip if path escapes project or home
        real_dir = os.path.realpath(extra_dir)
        real_project = os.path.realpath(project_dir)
        real_home = os.path.expanduser("~")
        # SEC-001 FIX: Add os.sep guard against prefix-collision bypass.
        if not (real_dir.startswith(real_project + os.sep) or real_dir == real_project
                or real_dir.startswith(real_home + os.sep) or real_dir == real_home):
            print("WARN: extra_agent_dir '%s' outside project/home — skipped" % extra_dir,
                  file=sys.stderr)
            continue
        for fpath in _valid_agent_files(real_dir):
            entry = parse_agent_file(fpath, "external")
            if entry:
                entries.append(entry)

    return entries


def _parse_talisman_user_agents(
    talisman_user_agents: Optional[List[Dict[str, Any]]],
) -> List[Dict[str, Any]]:
    """Parse inline user agent definitions from talisman.yml."""
    entries: List[Dict[str, Any]] = []

    if not talisman_user_agents or not isinstance(talisman_user_agents, list):
        return entries

    for i, agent_def in enumerate(talisman_user_agents):
        if not isinstance(agent_def, dict):
            continue
        name = agent_def.get("name", "user-agent-%d" % i)
        if not isinstance(name, str) or not VALID_NAME_RE.match(name):
            continue
        # Extract languages, normalize to lowercase
        user_langs_raw = agent_def.get("languages", [])
        if isinstance(user_langs_raw, str):
            user_langs_raw = [user_langs_raw]
        user_langs = [l.strip().lower() for l in user_langs_raw
                      if isinstance(l, str) and l.strip()]

        entry = {
            "id": generate_id(name, "user", "talisman:%d" % i),
            "name": name,
            "description": agent_def.get("description", ""),
            "category": agent_def.get("category", "unknown"),
            "primary_phase": "",
            "compatible_phases": agent_def.get("phases", []),
            "tags": agent_def.get("tags", []),
            "languages": user_langs,
            "source": "user",
            "priority": SOURCE_PRIORITIES["user"],
            "tools": agent_def.get("tools", []),
            "model": agent_def.get("model", ""),
            "max_turns": agent_def.get("maxTurns", 0),
            "body": agent_def.get("body", ""),
            "file_path": "talisman:user_agents[%d]" % i,
            "metadata": agent_def,
        }
        entries.append(entry)

    return entries


def discover_and_parse(
    plugin_root: str,
    project_dir: str,
    talisman_user_agents: Optional[List[Dict[str, Any]]] = None,
    extra_agent_dirs: Optional[List[str]] = None,
) -> List[Dict[str, Any]]:
    """Walk all 6 source directories and parse agent definitions.

    Sources (in priority order):
      1. agents/              (builtin, p100) — plugin's built-in agents
      2. registry/            (extended, p80) — extended agent registry
      3. .claude/agents/      (project, p75) — project-specific agents (auto-loaded by Claude Code)
      4. .rune/rune-agents/   (rune-project, p70) — search-only agents (NOT auto-loaded)
      5. extra_agent_dirs     (external, p60) — additional dirs from talisman
      6. talisman user_agents (user, p50) — user-defined via talisman.yml

    Args:
        plugin_root: Path to the plugin root directory.
        project_dir: Path to the project root directory.
        talisman_user_agents: Optional list of user agent defs from talisman.yml.
        extra_agent_dirs: Optional list of extra directory paths to scan.

    Returns:
        Combined list of agent entry dicts across all sources.
    """
    all_entries: List[Dict[str, Any]] = []

    # Sources 1-4: standard directory scans
    all_entries.extend(_scan_standard_sources(plugin_root, project_dir))

    # Source 5: extra agent directories (from talisman extra_agent_dirs)
    all_entries.extend(_scan_extra_dirs(extra_agent_dirs, project_dir))

    # Source 6: talisman user agents (inline definitions)
    all_entries.extend(_parse_talisman_user_agents(talisman_user_agents))

    return all_entries
