"""
Agent definition parser for the Agent Search MCP server.

Parses YAML frontmatter from agent .md files across 4 source directories:
  - agents/          (builtin, priority 100)
  - registry/        (extended, priority 80)
  - .claude/agents/  (project, priority 75)
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

# SEC-5: Agent name allowlist — lowercase + hyphens + digits + underscores
VALID_NAME_RE = re.compile(r'^[a-zA-Z0-9_-]+$')

# YAML frontmatter boundary
_FRONTMATTER_RE = re.compile(r'^---\s*$')

# Standard categories for agent classification
STANDARD_CATEGORIES = frozenset({
    "review", "investigation", "research", "work",
    "utility", "testing",
})

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


def _parse_frontmatter(lines: List[str]) -> Tuple[Dict[str, Any], int]:
    """Parse YAML frontmatter from lines, returning (metadata, body_start_line).

    Uses a simple line-based parser to avoid PyYAML dependency in the MCP
    server process. Handles scalar values, simple lists (- item), and
    multi-line strings (|).

    Args:
        lines: File lines (stripped of trailing newlines).

    Returns:
        Tuple of (parsed metadata dict, line index where body starts).
    """
    if not lines or not _FRONTMATTER_RE.match(lines[0]):
        return {}, 0

    metadata: Dict[str, Any] = {}
    current_key: Optional[str] = None
    current_list: Optional[List[str]] = None
    current_multiline: Optional[List[str]] = None
    body_start = len(lines)

    for i, line in enumerate(lines[1:], start=1):
        if _FRONTMATTER_RE.match(line):
            # Flush any pending state
            if current_key and current_list is not None:
                metadata[current_key] = current_list
            elif current_key and current_multiline is not None:
                metadata[current_key] = "\n".join(current_multiline).strip()
            body_start = i + 1
            break

        stripped = line.rstrip()

        # List item continuation
        if stripped.startswith("  - ") or stripped.startswith("  -\t"):
            if current_key and current_list is not None:
                item = stripped.strip()
                # Fix: remove only the first "- " prefix, not all leading dashes
                if item.startswith("- "):
                    item = item[2:]
                elif item.startswith("-"):
                    item = item[1:]
                current_list.append(item.strip())
                continue

        # Multiline string continuation (indented under |)
        if current_key and current_multiline is not None:
            if stripped.startswith("  ") or stripped == "":
                current_multiline.append(stripped.strip())
                continue
            else:
                # End of multiline — flush and fall through
                metadata[current_key] = "\n".join(current_multiline).strip()
                current_key = None
                current_multiline = None

        # Flush pending list
        if current_key and current_list is not None:
            metadata[current_key] = current_list
            current_key = None
            current_list = None

        # New key: value pair
        colon_pos = stripped.find(":")
        if colon_pos > 0:
            key = stripped[:colon_pos].strip()
            value = stripped[colon_pos + 1:].strip()

            if value == "|":
                # Start multiline string
                current_key = key
                current_multiline = []
                current_list = None
            elif value == "":
                # Could be start of a list
                current_key = key
                current_list = []
                current_multiline = None
            else:
                # Simple scalar
                current_key = None
                current_list = None
                current_multiline = None
                # Parse booleans and numbers
                if value.lower() in ("true", "yes"):
                    metadata[key] = True
                elif value.lower() in ("false", "no"):
                    metadata[key] = False
                else:
                    try:
                        metadata[key] = int(value)
                    except ValueError:
                        metadata[key] = value

    # Flush any remaining state
    if current_key and current_list is not None:
        metadata[current_key] = current_list
    elif current_key and current_multiline is not None:
        metadata[current_key] = "\n".join(current_multiline).strip()

    # Fix BACK-003: Detect unclosed frontmatter (no closing ---)
    if body_start == len(lines) and len(metadata) > 0:
        import sys
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
        Category string from STANDARD_CATEGORIES, or "unknown".
    """
    # Check parent directory
    parent_dir = os.path.basename(os.path.dirname(file_path))
    if parent_dir in STANDARD_CATEGORIES:
        return parent_dir

    # Check metadata
    category = metadata.get("category", "")
    if isinstance(category, str) and category.lower() in STANDARD_CATEGORIES:
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

    stripped_lines = [l.rstrip("\n") for l in lines]
    metadata, body_start = _parse_frontmatter(stripped_lines)

    if not metadata:
        print("WARN: no frontmatter in agent file: %s" % file_path, file=sys.stderr)
        return None

    # Derive name from metadata or filename
    name = metadata.get("name", "")
    if not isinstance(name, str) or not name:
        name = os.path.splitext(os.path.basename(file_path))[0]

    # SEC-5: Validate name
    if not VALID_NAME_RE.match(name):
        print("WARN: invalid agent name '%s' in %s — skipped" % (name, file_path),
              file=sys.stderr)
        return None

    description = metadata.get("description", "")
    if not isinstance(description, str):
        description = str(description)

    category = _infer_category(file_path, metadata)
    phases = _infer_phases(metadata, category)
    body = "\n".join(stripped_lines[body_start:]).strip()
    tags = _extract_tags(metadata, body)

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
        "tools": metadata.get("tools", []),
        "model": metadata.get("model", ""),
        "max_turns": metadata.get("maxTurns", 0),
        "body": body,
        "file_path": file_path,
        "metadata": metadata,
    }


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
        if not os.path.realpath(root).startswith(real_parent):
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
            if os.path.realpath(fpath).startswith(real_parent):
                results.append(fpath)

    return results


def discover_and_parse(
    plugin_root: str,
    project_dir: str,
    talisman_user_agents: Optional[List[Dict[str, Any]]] = None,
) -> List[Dict[str, Any]]:
    """Walk all 4 source directories and parse agent definitions.

    Sources (in priority order):
      1. agents/          (builtin, p100) — plugin's built-in agents
      2. registry/        (extended, p80) — extended agent registry
      3. .claude/agents/  (project, p75) — project-specific agents
      4. talisman user_agents (user, p50) — user-defined via talisman.yml

    Args:
        plugin_root: Path to the plugin root directory.
        project_dir: Path to the project root directory.
        talisman_user_agents: Optional list of user agent defs from talisman.yml.

    Returns:
        Combined list of agent entry dicts across all sources.
    """
    all_entries: List[Dict[str, Any]] = []

    # Source 1: builtin agents (agents/)
    builtin_dir = os.path.join(plugin_root, "agents")
    for fpath in _valid_agent_files(builtin_dir):
        entry = parse_agent_file(fpath, "builtin")
        if entry:
            all_entries.append(entry)

    # Source 2: extended registry (registry/)
    registry_dir = os.path.join(plugin_root, "registry")
    for fpath in _valid_agent_files(registry_dir):
        entry = parse_agent_file(fpath, "extended")
        if entry:
            all_entries.append(entry)

    # Source 3: project agents (.claude/agents/)
    project_agents_dir = os.path.join(project_dir, ".claude", "agents")
    for fpath in _valid_agent_files(project_agents_dir):
        entry = parse_agent_file(fpath, "project")
        if entry:
            all_entries.append(entry)

    # Source 4: talisman user agents (inline definitions)
    if talisman_user_agents and isinstance(talisman_user_agents, list):
        for i, agent_def in enumerate(talisman_user_agents):
            if not isinstance(agent_def, dict):
                continue
            name = agent_def.get("name", "user-agent-%d" % i)
            if not isinstance(name, str) or not VALID_NAME_RE.match(name):
                continue
            entry = {
                "id": generate_id(name, "user", "talisman:%d" % i),
                "name": name,
                "description": agent_def.get("description", ""),
                "category": agent_def.get("category", "unknown"),
                "primary_phase": "",
                "compatible_phases": agent_def.get("phases", []),
                "tags": agent_def.get("tags", []),
                "source": "user",
                "priority": SOURCE_PRIORITIES["user"],
                "tools": agent_def.get("tools", []),
                "model": agent_def.get("model", ""),
                "max_turns": agent_def.get("maxTurns", 0),
                "body": agent_def.get("body", ""),
                "file_path": "talisman:user_agents[%d]" % i,
                "metadata": agent_def,
            }
            all_entries.append(entry)

    return all_entries
