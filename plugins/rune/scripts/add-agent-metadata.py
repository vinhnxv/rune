#!/usr/bin/env python3
"""
Add registry metadata fields to agent YAML frontmatter.

Scans all plugins/rune/agents/**/*.md files and adds NEW fields
(categories, primary_phase, compatible_phases, tags, source, priority)
without overwriting any existing frontmatter fields.

Usage:
    python3 plugins/rune/scripts/add-agent-metadata.py [--dry-run]

Requires: PyYAML (pip install pyyaml)
"""

from __future__ import annotations

import re
import sys
from pathlib import Path
from typing import Optional

try:
    import yaml
except ImportError:
    print("ERROR: PyYAML is required. Install with: pip install pyyaml", file=sys.stderr)
    sys.exit(1)


SCRIPT_DIR = Path(__file__).resolve().parent
PLUGIN_ROOT = SCRIPT_DIR.parent
AGENTS_DIR = PLUGIN_ROOT / "agents"

# Subdirectory → primary_phase mapping
SUBDIR_TO_PHASE: dict[str, str] = {
    "review": "review",
    "investigation": "goldmask",
    "testing": "test",
    "work": "work",
    "utility": "utility",
    "research": "devise",
}

# Subdirectory → compatible_phases mapping
SUBDIR_TO_COMPATIBLE: dict[str, list[str]] = {
    "review": ["review", "audit", "arc"],
    "investigation": ["goldmask", "inspect", "arc"],
    "testing": ["test", "arc"],
    "work": ["work", "arc", "mend"],
    "utility": ["devise", "arc", "forge", "mend"],
    "research": ["devise", "forge", "arc"],
}

# Subdirectory → default categories
SUBDIR_TO_CATEGORIES: dict[str, list[str]] = {
    "review": ["code-review"],
    "investigation": ["impact-analysis"],
    "testing": ["testing"],
    "work": ["implementation"],
    "utility": ["orchestration"],
    "research": ["research"],
}

# Stop words to filter out when extracting tags from descriptions
STOP_WORDS: set[str] = {
    "a", "an", "the", "and", "or", "but", "in", "on", "at", "to", "for",
    "of", "with", "by", "from", "is", "are", "was", "were", "be", "been",
    "being", "have", "has", "had", "do", "does", "did", "will", "would",
    "could", "should", "may", "might", "must", "shall", "can", "not",
    "this", "that", "these", "those", "it", "its", "use", "used", "using",
    "when", "where", "how", "what", "which", "who", "whom", "why",
    "all", "each", "every", "both", "few", "more", "most", "other",
    "some", "such", "no", "nor", "only", "own", "same", "so", "than",
    "too", "very", "just", "about", "above", "after", "again", "also",
    "e", "g", "i", "etc", "via", "vs", "based", "across", "between",
    "through", "during", "before", "into", "against", "over", "under",
    "covers", "ensures", "detects", "identifies", "finds", "checks",
    "verifies", "validates", "evaluates", "analyzes", "reviews",
    "provides", "runs", "agent", "agents",
}

# Domain keywords → additional category mappings
KEYWORD_CATEGORIES: dict[str, str] = {
    "security": "security",
    "vulnerability": "security",
    "auth": "security",
    "injection": "security",
    "performance": "performance",
    "bottleneck": "performance",
    "latency": "performance",
    "memory": "performance",
    "architecture": "architecture",
    "design": "architecture",
    "coupling": "architecture",
    "dependency": "architecture",
    "test": "testing",
    "coverage": "testing",
    "assertion": "testing",
    "tdd": "testing",
    "dead code": "code-quality",
    "complexity": "code-quality",
    "duplication": "code-quality",
    "naming": "code-quality",
    "ux": "ux",
    "accessibility": "ux",
    "usability": "ux",
    "frontend": "frontend",
    "documentation": "documentation",
    "migration": "data",
    "schema": "data",
    "database": "data",
    "observability": "observability",
    "logging": "observability",
    "metrics": "observability",
    "monitoring": "observability",
}


def parse_frontmatter(content: str) -> tuple[Optional[dict], str, str]:
    """Parse YAML frontmatter from markdown content.

    Returns:
        Tuple of (frontmatter_dict, raw_frontmatter_text, body_text).
        frontmatter_dict is None if no valid frontmatter found.
    """
    # Match opening --- through closing --- with DOTALL for multiline
    match = re.match(r"^---\n(.*?)\n---\s*\n", content, re.DOTALL)
    if match is None:
        return None, "", content

    raw_fm = match.group(1)
    body = content[match.end() :]

    try:
        data = yaml.safe_load(raw_fm)
    except yaml.YAMLError as e:
        print(f"  WARN: YAML parse error: {e}", file=sys.stderr)
        return None, raw_fm, body

    if not isinstance(data, dict):
        return None, raw_fm, body

    return data, raw_fm, body


def extract_tags(description: str, name: str) -> list[str]:
    """Extract meaningful keyword tags from agent description and name.

    Args:
        description: The agent's description text.
        name: The agent's name (hyphen-separated).

    Returns:
        Sorted list of unique, lowercase tags (max 10).
    """
    if not description:
        return []

    # Combine description + name words
    text = f"{description} {name.replace('-', ' ')}".lower()

    # Extract words (3+ chars, alphanumeric)
    words = re.findall(r"[a-z][a-z0-9]{2,}", text)

    # Filter stop words and deduplicate
    tags = sorted({w for w in words if w not in STOP_WORDS and len(w) <= 25})

    # Keep most relevant (prefer longer, more specific words)
    tags.sort(key=lambda t: (-len(t), t))
    return tags[:10]


def infer_categories(
    description: str, subdir: str, existing: Optional[list[str]]
) -> list[str]:
    """Infer categories from description keywords and subdirectory.

    Args:
        description: The agent's description text.
        subdir: The subdirectory name (review, investigation, etc.).
        existing: Any existing categories to preserve.

    Returns:
        Deduplicated list of categories.
    """
    categories: list[str] = list(existing) if existing else []

    # Add subdirectory-based defaults
    for cat in SUBDIR_TO_CATEGORIES.get(subdir, []):
        if cat not in categories:
            categories.append(cat)

    # Scan description for keyword matches
    desc_lower = (description or "").lower()
    for keyword, category in KEYWORD_CATEGORIES.items():
        if keyword in desc_lower and category not in categories:
            categories.append(category)

    return categories


def build_updated_frontmatter(
    data: dict, subdir: str, raw_fm: str
) -> tuple[str, bool]:
    """Add new metadata fields to frontmatter without overwriting existing ones.

    Args:
        data: Parsed frontmatter dict.
        subdir: The subdirectory name for phase inference.
        raw_fm: The raw frontmatter YAML text.

    Returns:
        Tuple of (new_frontmatter_yaml, was_modified).
    """
    modified = False
    name = data.get("name", "")
    description = data.get("description", "")

    # Normalize description to string
    if isinstance(description, str):
        desc_text = description.strip()
    else:
        desc_text = str(description).strip() if description else ""

    # Add source (always "builtin")
    if "source" not in data:
        data["source"] = "builtin"
        modified = True

    # Add priority (always 100 for builtin)
    if "priority" not in data:
        data["priority"] = 100
        modified = True

    # Add primary_phase
    if "primary_phase" not in data:
        data["primary_phase"] = SUBDIR_TO_PHASE.get(subdir, "general")
        modified = True

    # Add compatible_phases
    if "compatible_phases" not in data:
        data["compatible_phases"] = SUBDIR_TO_COMPATIBLE.get(
            subdir, [SUBDIR_TO_PHASE.get(subdir, "general")]
        )
        modified = True

    # Add categories
    if "categories" not in data:
        data["categories"] = infer_categories(desc_text, subdir, None)
        modified = True

    # Add tags
    if "tags" not in data:
        data["tags"] = extract_tags(desc_text, name)
        modified = True

    if not modified:
        return raw_fm, False

    # Serialize back to YAML, preserving key order as best we can
    # We want a specific field order for readability
    ordered_keys = [
        "name",
        "description",
        "model",
        "tools",
        "disallowedTools",
        "maxTurns",
        "mcpServers",
        "permissionMode",
        "memory",
        "skills",
        "hooks",
        # New metadata fields
        "source",
        "priority",
        "primary_phase",
        "compatible_phases",
        "categories",
        "tags",
    ]

    lines: list[str] = []
    emitted: set[str] = set()

    for key in ordered_keys:
        if key in data:
            val = data[key]
            lines.append(_yaml_field(key, val))
            emitted.add(key)

    # Emit any remaining keys not in our ordered list
    for key in data:
        if key not in emitted:
            lines.append(_yaml_field(key, data[key]))

    return "\n".join(lines) + "\n", True


def _yaml_field(key: str, value: object) -> str:
    """Serialize a single YAML field, handling multi-line strings and lists.

    Args:
        key: The YAML key name.
        value: The value to serialize.

    Returns:
        YAML-formatted string for this field.
    """
    if isinstance(value, str) and "\n" in value:
        # Multi-line string with block scalar
        indent = "  "
        lines = value.rstrip("\n").split("\n")
        block = "\n".join(f"{indent}{line}" for line in lines)
        return f"{key}: |\n{block}"
    elif isinstance(value, list):
        if not value:
            return f"{key}: []"
        # Check if items contain comments (from raw parsing)
        items = []
        for item in value:
            if isinstance(item, str):
                items.append(f"  - {item}")
            else:
                # Fallback for non-string items
                items.append(f"  - {yaml.dump(item, default_flow_style=True).strip()}")
        return f"{key}:\n" + "\n".join(items)
    elif isinstance(value, bool):
        return f"{key}: {'true' if value else 'false'}"
    elif isinstance(value, (int, float)):
        return f"{key}: {value}"
    elif value is None:
        return f"{key}:"
    else:
        # Simple scalar
        val_str = str(value)
        # Quote if contains special YAML chars
        if any(c in val_str for c in ":{}\n[]&*?|>!%@`"):
            return f'{key}: "{val_str}"'
        return f"{key}: {val_str}"


def process_agent_file(filepath: Path, dry_run: bool = False) -> str:
    """Process a single agent .md file and add metadata if needed.

    Args:
        filepath: Path to the agent .md file.
        dry_run: If True, don't write changes.

    Returns:
        Status string: "updated", "skipped" (already has metadata), or "error".
    """
    try:
        content = filepath.read_text(encoding="utf-8")
    except OSError as e:
        print(f"  ERROR reading {filepath}: {e}", file=sys.stderr)
        return "error"

    data, raw_fm, body = parse_frontmatter(content)
    if data is None:
        print(f"  WARN: No valid frontmatter in {filepath.name}", file=sys.stderr)
        return "error"

    # Determine subdirectory (review, investigation, etc.)
    rel = filepath.relative_to(AGENTS_DIR)
    subdir = rel.parts[0] if len(rel.parts) > 1 else "unknown"

    new_fm, was_modified = build_updated_frontmatter(data, subdir, raw_fm)
    if not was_modified:
        return "skipped"

    # Reconstruct the file
    new_content = f"---\n{new_fm}---\n{body}"

    if not dry_run:
        try:
            filepath.write_text(new_content, encoding="utf-8")
        except OSError as e:
            print(f"  ERROR writing {filepath}: {e}", file=sys.stderr)
            return "error"

    return "updated"


def main() -> None:
    """Scan all agent .md files and add registry metadata."""
    dry_run = "--dry-run" in sys.argv

    if not AGENTS_DIR.is_dir():
        print(f"ERROR: Agents directory not found: {AGENTS_DIR}", file=sys.stderr)
        sys.exit(1)

    # Collect all .md files (exclude references/ subdirectories)
    agent_files = sorted(
        f
        for f in AGENTS_DIR.rglob("*.md")
        if "references" not in f.parts and f.name != "README.md"
    )

    if not agent_files:
        print("No agent files found.")
        sys.exit(0)

    updated = 0
    skipped = 0
    errors = 0

    mode_label = " (dry-run)" if dry_run else ""
    print(f"Scanning {len(agent_files)} agent files{mode_label}...")

    for filepath in agent_files:
        rel_path = filepath.relative_to(PLUGIN_ROOT)
        result = process_agent_file(filepath, dry_run)

        if result == "updated":
            print(f"  + {rel_path}")
            updated += 1
        elif result == "skipped":
            skipped += 1
        else:
            errors += 1

    print(f"\nSummary: {updated} updated, {skipped} already had metadata, {errors} errors")

    if dry_run and updated > 0:
        print("(No files were modified — re-run without --dry-run to apply)")


if __name__ == "__main__":
    main()
