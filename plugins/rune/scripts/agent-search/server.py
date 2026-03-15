"""
Agent Search MCP Server

A Model Context Protocol (MCP) stdio server that provides full-text search
over Rune agent definitions (agents/*.md, registry/*.md, .claude/agents/*.md,
and talisman user_agents).

Provides 5 tools:
  - agent_search:   Hybrid BM25 + multi-factor scoring for agent discovery
  - agent_detail:   Fetch full agent frontmatter + body by name
  - agent_register: Register user/project agent definitions
  - agent_stats:    Summary statistics of the agent index
  - agent_reindex:  Force rebuild the FTS5 index

Environment variables:
  PLUGIN_ROOT   - Path to the Rune plugin root directory
  PROJECT_DIR   - Path to the project root directory
  DB_PATH       - Path to the SQLite database file

Usage:
  # As MCP stdio server (normal mode):
  python3 server.py

  # Standalone reindex:
  python3 server.py --reindex
"""

from __future__ import annotations

import argparse
import json
import logging
import os
import re
import sqlite3
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger("agent-search")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

PLUGIN_ROOT = os.environ.get("PLUGIN_ROOT", "")
PROJECT_DIR = os.environ.get("PROJECT_DIR", "")
DB_PATH = os.environ.get("DB_PATH", "")

# SEC-001/SEC-003: Validate env vars don't point to system or sensitive directories
_FORBIDDEN_PREFIXES = (
    "/etc", "/usr", "/bin", "/sbin", "/var/run", "/proc", "/sys",
    os.path.expanduser("~/.ssh"),
    os.path.expanduser("~/.gnupg"),
    os.path.expanduser("~/.aws"),
)
for _env_name, _env_val in [("PLUGIN_ROOT", PLUGIN_ROOT),
                             ("PROJECT_DIR", PROJECT_DIR),
                             ("DB_PATH", DB_PATH)]:
    if _env_val:
        _resolved = os.path.realpath(_env_val)
        if any(_resolved.startswith(p) for p in _FORBIDDEN_PREFIXES):
            print(
                "Error: %s points to system directory: %s" % (_env_name, _resolved),
                file=sys.stderr,
            )
            sys.exit(1)

if DB_PATH:
    _db_resolved = os.path.realpath(DB_PATH)
    if not (_db_resolved.endswith(".db") or _db_resolved.endswith(".sqlite")):
        print(
            "Error: DB_PATH must end with .db or .sqlite: %s" % _db_resolved,
            file=sys.stderr,
        )
        sys.exit(1)
    # SEC-007: Allowlist DB_PATH parent directory
    _db_parent = os.path.dirname(_db_resolved)
    _home = os.path.expanduser("~")
    _cwd = os.path.realpath(os.getcwd())
    _tmpdir = os.path.realpath(os.environ.get("TMPDIR", "/tmp"))
    _allowed_prefixes = (_home, _cwd, _tmpdir)
    if not any(_db_parent.startswith(p + os.sep) or _db_parent == p
               for p in _allowed_prefixes):
        print(
            "Error: DB_PATH must be under home, project, or temp directory: %s"
            % _db_resolved,
            file=sys.stderr,
        )
        sys.exit(1)

# ---------------------------------------------------------------------------
# Scoring weights — hybrid ranking
# ---------------------------------------------------------------------------
# Composite scoring: BM25 (0.4) + tag_match (0.3) + phase_match (0.2)
#                    + category_match (0.1) + source_priority_bonus

_DEFAULT_WEIGHTS = {
    "bm25": 0.40,
    "tag_match": 0.30,
    "phase_match": 0.20,
    "category_match": 0.10,
}

# Source priority bonus (added to composite, not weighted)
_SOURCE_PRIORITY_BONUS = {
    100: 0.05,  # builtin
    80: 0.03,   # extended
    75: 0.02,   # project
    50: 0.00,   # user
}

# ---------------------------------------------------------------------------
# Dirty signal helpers (consumed from annotate-dirty.sh)
# ---------------------------------------------------------------------------


def _signal_path(project_dir: str) -> str:
    """Derive the dirty-signal file path from PROJECT_DIR.

    The PostToolUse hook writes the signal to
    ``<project>/tmp/.rune-signals/.agent-dirty``.

    Args:
        project_dir: Project root directory.

    Returns:
        Absolute path to the dirty signal file, or empty string.
    """
    if not project_dir:
        return ""
    # SEC-007: Re-canonicalize to prevent path traversal
    real_dir = os.path.realpath(project_dir)
    return os.path.join(real_dir, "tmp", ".rune-signals", ".agent-dirty")


def _search_signal_path(project_dir: str) -> str:
    """Derive the search-called signal file path.

    Written on every agent_search() call for enforce-agent-search.sh hook.

    Args:
        project_dir: Project root directory.

    Returns:
        Absolute path to the search-called signal file.
    """
    if not project_dir:
        return ""
    real_dir = os.path.realpath(project_dir)
    return os.path.join(real_dir, "tmp", ".rune-signals", ".agent-search-called")


def _check_and_clear_dirty(project_dir: str) -> bool:
    """Return True (and delete the file) if the dirty signal is present.

    Args:
        project_dir: Project root directory.

    Returns:
        True if dirty signal was found and cleared.
    """
    path = _signal_path(project_dir)
    if not path:
        return False
    try:
        if os.path.isfile(path):
            os.remove(path)
            return True
    except OSError:
        pass  # Race with another consumer — safe to ignore
    return False


def _write_search_signal(project_dir: str) -> None:
    """Write the search-called signal file.

    Args:
        project_dir: Project root directory.
    """
    path = _search_signal_path(project_dir)
    if not path:
        return
    try:
        signal_dir = os.path.dirname(path)
        os.makedirs(signal_dir, exist_ok=True)
        with open(path, "w") as f:
            f.write("1")
    except OSError:
        pass  # Non-critical — don't fail the search


# ---------------------------------------------------------------------------
# SQL helpers
# ---------------------------------------------------------------------------

def _in_clause(count: int) -> str:  # noqa: F811 — used by do_detail SQL
    """Build a parameterized IN-clause placeholder string.

    Returns a string like ``?,?,?`` for *count* parameters.
    SAFE: Only literal ``?`` characters — never user data.
    """
    return ",".join(["?"] * count)


# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

SCHEMA_VERSION = 1


def get_db(db_path: str) -> sqlite3.Connection:
    """Open a SQLite connection with WAL mode and Row factory.

    Args:
        db_path: Absolute path to the SQLite database file.

    Returns:
        Connection with row_factory=sqlite3.Row, WAL mode, busy_timeout=5000ms.
    """
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    return conn


def ensure_schema(conn: sqlite3.Connection) -> None:
    """Create or migrate the database schema.

    Applies versioned migrations idempotently.

    Args:
        conn: Active database connection.
    """
    conn.execute(
        "CREATE TABLE IF NOT EXISTS agent_meta "
        "(key TEXT PRIMARY KEY, value TEXT)"
    )

    current = 0
    try:
        row = conn.execute(
            "SELECT value FROM agent_meta WHERE key = 'schema_version'"
        ).fetchone()
        if row:
            current = int(row["value"])
    except (sqlite3.OperationalError, ValueError, TypeError):
        pass

    if current < 1:
        _migrate_v1(conn)

    conn.execute(
        "INSERT OR REPLACE INTO agent_meta (key, value) VALUES (?, ?)",
        ("schema_version", str(SCHEMA_VERSION)),
    )
    conn.commit()


def _migrate_v1(conn: sqlite3.Connection) -> None:
    """Apply V1 schema: core agent tables and FTS5 index."""
    conn.execute("""CREATE TABLE IF NOT EXISTS agent_entries (
        id TEXT PRIMARY KEY,
        name TEXT NOT NULL UNIQUE,
        description TEXT NOT NULL DEFAULT '',
        category TEXT NOT NULL DEFAULT 'unknown',
        primary_phase TEXT DEFAULT '',
        compatible_phases TEXT DEFAULT '',
        tags TEXT DEFAULT '',
        source TEXT NOT NULL DEFAULT 'builtin',
        priority INTEGER NOT NULL DEFAULT 50,
        tools TEXT DEFAULT '',
        model TEXT DEFAULT '',
        max_turns INTEGER DEFAULT 0,
        body TEXT DEFAULT '',
        file_path TEXT NOT NULL DEFAULT '',
        indexed_at TEXT NOT NULL DEFAULT ''
    )""")

    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_agent_entries_category "
        "ON agent_entries(category)"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_agent_entries_source "
        "ON agent_entries(source)"
    )
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_agent_entries_primary_phase "
        "ON agent_entries(primary_phase)"
    )

    # FTS5 virtual table for full-text search
    cursor = conn.execute(
        "SELECT name FROM sqlite_master "
        "WHERE type='table' AND name='agent_entries_fts'"
    )
    if cursor.fetchone() is None:
        conn.execute("""CREATE VIRTUAL TABLE agent_entries_fts USING fts5(
            name, description, tags, body,
            content=agent_entries,
            tokenize='porter unicode61'
        )""")


def rebuild_index(
    conn: sqlite3.Connection,
    entries: List[Dict[str, Any]],
) -> int:
    """Rebuild the full-text search index from parsed agent entries.

    Drops and recreates all rows. FTS5 triggers handle index sync.

    Args:
        conn: Active database connection.
        entries: List of agent entry dicts from indexer.discover_and_parse().

    Returns:
        Number of entries indexed.
    """
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    # Clear existing entries
    conn.execute("DELETE FROM agent_entries")
    # Rebuild FTS content
    conn.execute("DELETE FROM agent_entries_fts")

    count = 0
    for entry in entries:
        name = entry.get("name", "")
        if not name:
            continue

        phases_str = ",".join(entry.get("compatible_phases", []))
        tags_str = ",".join(entry.get("tags", []))
        tools_str = ",".join(str(t) for t in entry.get("tools", []))

        try:
            conn.execute(
                """INSERT OR REPLACE INTO agent_entries
                   (id, name, description, category, primary_phase,
                    compatible_phases, tags, source, priority,
                    tools, model, max_turns, body, file_path, indexed_at)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    entry.get("id", ""),
                    name,
                    entry.get("description", ""),
                    entry.get("category", "unknown"),
                    entry.get("primary_phase", ""),
                    phases_str,
                    tags_str,
                    entry.get("source", "builtin"),
                    entry.get("priority", 50),
                    tools_str,
                    entry.get("model", ""),
                    entry.get("max_turns", 0),
                    entry.get("body", ""),
                    entry.get("file_path", ""),
                    now,
                ),
            )
            # Manual FTS sync (content= table requires manual insert)
            conn.execute(
                """INSERT INTO agent_entries_fts
                   (rowid, name, description, tags, body)
                   VALUES (
                       (SELECT rowid FROM agent_entries WHERE id = ?),
                       ?, ?, ?, ?
                   )""",
                (
                    entry.get("id", ""),
                    name,
                    entry.get("description", ""),
                    tags_str,
                    entry.get("body", ""),
                ),
            )
            count += 1
        except sqlite3.IntegrityError as exc:
            # Duplicate name from different sources — higher priority wins
            logger.debug("Skipping duplicate agent '%s': %s", name, exc)

    conn.commit()
    return count


# ---------------------------------------------------------------------------
# Scoring functions
# ---------------------------------------------------------------------------


def _score_bm25_relevance(scores: List[float]) -> List[float]:
    """Normalize BM25 scores to 0.0-1.0 range via min-max scaling.

    FTS5 bm25() returns negative values where more negative = more relevant.
    We invert: 1.0 = most relevant, 0.0 = least relevant.

    Args:
        scores: Raw BM25 scores (negative floats) from FTS5.

    Returns:
        List of normalized scores in [0.0, 1.0].
    """
    if not scores:
        return []
    if len(scores) == 1:
        return [1.0]
    bm25_min = min(scores)
    bm25_max = max(scores)
    spread = bm25_max - bm25_min
    if abs(spread) < 1e-9:
        return [1.0] * len(scores)
    return [(bm25_max - s) / spread for s in scores]


def _score_tag_match(
    entry_tags: str,
    query_terms: List[str],
) -> float:
    """Score tag overlap between entry tags and query terms.

    Args:
        entry_tags: Comma-separated tag string from the entry.
        query_terms: Lowercased query terms.

    Returns:
        Ratio of matching tags to total query terms, in [0.0, 1.0].
    """
    if not query_terms:
        return 0.0
    tags_lower = set(t.strip().lower() for t in entry_tags.split(",") if t.strip())
    if not tags_lower:
        return 0.0
    matches = sum(1 for term in query_terms if any(term in tag for tag in tags_lower))
    return min(matches / len(query_terms), 1.0)


def _score_phase_match(
    entry_phases: str,
    target_phase: Optional[str],
) -> float:
    """Score whether the entry's phases include the target phase.

    Args:
        entry_phases: Comma-separated phase string from the entry.
        target_phase: Target phase to match (or None/empty).

    Returns:
        1.0 if primary phase matches, 0.5 if compatible, 0.0 otherwise.
    """
    if not target_phase:
        return 0.0
    phases = [p.strip().lower() for p in entry_phases.split(",") if p.strip()]
    target = target_phase.strip().lower()
    if not phases:
        return 0.0
    if phases[0] == target:
        return 1.0  # Primary phase match
    if target in phases:
        return 0.5  # Compatible phase match
    return 0.0


def _score_category_match(
    entry_category: str,
    target_category: Optional[str],
) -> float:
    """Score whether the entry's category matches the target.

    Args:
        entry_category: Entry category string.
        target_category: Target category (or None/empty).

    Returns:
        1.0 if exact match, 0.0 otherwise.
    """
    if not target_category:
        return 0.0
    return 1.0 if entry_category.lower() == target_category.lower() else 0.0


def compute_composite_score(
    results: List[Dict[str, Any]],
    query: str,
    phase: Optional[str] = None,
    category: Optional[str] = None,
) -> List[Dict[str, Any]]:
    """Re-rank search results using hybrid multi-factor scoring.

    Scoring formula:
      composite = bm25_weight * bm25_norm
                + tag_weight * tag_match_ratio
                + phase_weight * phase_match
                + category_weight * category_match
                + source_priority_bonus

    Args:
        results: Search result dicts with 'bm25_score', 'tags', etc.
        query: Original search query.
        phase: Optional phase filter for phase_match scoring.
        category: Optional category filter for category_match scoring.

    Returns:
        Re-sorted results with 'composite_score' and 'score_factors'.
    """
    if not results:
        return []

    # Tokenize query for tag matching
    query_terms = [
        t.lower() for t in re.split(r'\s+', query.strip())
        if len(t) > 1
    ]

    raw_bm25 = [r.get("bm25_score", 0.0) for r in results]
    norm_bm25 = _score_bm25_relevance(raw_bm25)

    scored: List[Tuple[float, Dict[str, Any]]] = []
    for i, entry in enumerate(results):
        tag_score = _score_tag_match(entry.get("tags", ""), query_terms)
        phase_score = _score_phase_match(
            entry.get("compatible_phases", ""), phase)
        cat_score = _score_category_match(
            entry.get("category", ""), category)

        priority = entry.get("priority", 50)
        bonus = _SOURCE_PRIORITY_BONUS.get(priority, 0.0)

        composite = (
            _DEFAULT_WEIGHTS["bm25"] * norm_bm25[i]
            + _DEFAULT_WEIGHTS["tag_match"] * tag_score
            + _DEFAULT_WEIGHTS["phase_match"] * phase_score
            + _DEFAULT_WEIGHTS["category_match"] * cat_score
            + bonus
        )

        enriched = dict(entry)
        enriched["composite_score"] = round(composite, 4)
        enriched["score_factors"] = {
            "bm25": round(norm_bm25[i], 4),
            "tag_match": round(tag_score, 4),
            "phase_match": round(phase_score, 4),
            "category_match": round(cat_score, 4),
            "source_bonus": round(bonus, 4),
        }
        scored.append((composite, enriched))

    scored.sort(key=lambda x: x[0], reverse=True)
    return [entry for _, entry in scored]


# ---------------------------------------------------------------------------
# Core operations
# ---------------------------------------------------------------------------

def do_search(
    db_path: str,
    query: str,
    phase: Optional[str] = None,
    category: Optional[str] = None,
    source: Optional[str] = None,
    exclude: Optional[List[str]] = None,
    limit: int = 5,
) -> Dict[str, Any]:
    """Execute an agent search with hybrid scoring.

    Args:
        db_path: Path to the SQLite database.
        query: Search query string.
        phase: Optional phase filter.
        category: Optional category filter.
        source: Optional source filter (builtin, extended, project, user).
        exclude: Optional list of agent names to exclude.
        limit: Maximum results to return (default 5, max 20).

    Returns:
        Dict with 'results', 'total', 'query', and timing info.
    """
    start_ms = int(time.time() * 1000)
    limit = max(1, min(limit, 20))

    conn = get_db(db_path)
    try:
        ensure_schema(conn)

        # Check for dirty signal and reindex if needed
        if _check_and_clear_dirty(PROJECT_DIR):
            logger.info("Dirty signal detected — triggering auto-reindex")
            _do_reindex_internal(conn)

        # Build FTS5 query — sanitize for safety
        fts_query = _sanitize_fts_query(query)
        if not fts_query:
            return {"results": [], "total": 0, "query": query, "time_ms": 0}

        # Execute BM25 search with broader fetch for re-ranking
        fetch_limit = min(limit * 3, 60)  # Fetch 3x for re-ranking headroom

        sql = """
            SELECT e.*, bm25(agent_entries_fts) AS bm25_score
            FROM agent_entries_fts f
            JOIN agent_entries e ON f.rowid = e.rowid
            WHERE agent_entries_fts MATCH ?
        """
        params: List[Any] = [fts_query]

        # Apply filters via SQL WHERE clauses
        if category:
            sql += " AND e.category = ?"
            params.append(category)
        if source:
            sql += " AND e.source = ?"
            params.append(source)

        sql += " ORDER BY bm25(agent_entries_fts) LIMIT ?"
        params.append(fetch_limit)

        try:
            rows = conn.execute(sql, params).fetchall()
        except sqlite3.OperationalError as exc:
            # FTS5 query syntax error — try plain prefix search
            logger.debug("FTS5 query failed, trying prefix: %s", exc)
            fts_query = _fallback_fts_query(query)
            if not fts_query:
                return {"results": [], "total": 0, "query": query, "time_ms": 0}
            params[0] = fts_query
            rows = conn.execute(sql, params).fetchall()

        # Convert to dicts
        results = [dict(row) for row in rows]

        # Apply exclusions
        if exclude:
            exclude_set = set(n.lower() for n in exclude)
            results = [r for r in results if r.get("name", "").lower() not in exclude_set]

        # Re-rank with composite scoring
        results = compute_composite_score(results, query, phase, category)

        # Trim to requested limit
        total = len(results)
        results = results[:limit]

        # Clean up results for output (remove body to save tokens)
        for r in results:
            r.pop("body", None)
            r.pop("bm25_score", None)
            # Parse phases back to list
            phases_str = r.get("compatible_phases", "")
            if isinstance(phases_str, str):
                r["compatible_phases"] = [
                    p.strip() for p in phases_str.split(",") if p.strip()
                ]
            # Parse tags back to list
            tags_str = r.get("tags", "")
            if isinstance(tags_str, str):
                r["tags"] = [t.strip() for t in tags_str.split(",") if t.strip()]

    finally:
        conn.close()

    elapsed_ms = int(time.time() * 1000) - start_ms

    return {
        "results": results,
        "total": total,
        "query": query,
        "filters": {
            "phase": phase,
            "category": category,
            "source": source,
            "exclude": exclude or [],
        },
        "time_ms": elapsed_ms,
    }


def do_detail(db_path: str, name: str) -> Dict[str, Any]:
    """Fetch full agent detail by name.

    Args:
        db_path: Path to the SQLite database.
        name: Agent name to look up.

    Returns:
        Dict with full agent data including body, or error dict.
    """
    conn = get_db(db_path)
    try:
        ensure_schema(conn)
        row = conn.execute(
            "SELECT * FROM agent_entries WHERE name = ?",
            (name,),
        ).fetchone()

        if row is None:
            return {"error": "Agent not found: %s" % name}

        result = dict(row)
        # Parse lists
        for field in ("compatible_phases", "tags", "tools"):
            val = result.get(field, "")
            if isinstance(val, str):
                result[field] = [v.strip() for v in val.split(",") if v.strip()]
        return result
    finally:
        conn.close()


def do_register(
    db_path: str,
    name: str,
    description: str,
    categories: List[str],
    primary_phase: str,
    compatible_phases: List[str],
    tags: List[str],
    body: str,
    source: str = "user",
) -> Dict[str, Any]:
    """Register a user/project agent definition.

    Args:
        db_path: Path to the SQLite database.
        name: Agent name (lowercase + hyphens).
        description: Agent description.
        categories: Agent categories.
        primary_phase: Primary phase name.
        compatible_phases: List of compatible phases.
        tags: List of tags.
        body: Agent body markdown.
        source: Source category (default "user").

    Returns:
        Dict with registration result or error.
    """
    from schema import validate_agent_schema

    # Validate
    errors = validate_agent_schema(
        name=name,
        description=description,
        source=source,
    )
    if errors:
        return {"error": "Validation failed", "details": errors}

    conn = get_db(db_path)
    try:
        ensure_schema(conn)

        # Check for builtin conflict
        existing = conn.execute(
            "SELECT source FROM agent_entries WHERE name = ?",
            (name,),
        ).fetchone()
        if existing and existing["source"] == "builtin":
            return {
                "error": "Cannot overwrite builtin agent: %s" % name,
                "hint": "Use a different name or register as a project agent",
            }

        from indexer import generate_id, SOURCE_PRIORITIES

        entry_id = generate_id(name, source, "registered:%s" % name)
        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        category = categories[0] if categories else "unknown"
        phases_str = ",".join(compatible_phases)
        tags_str = ",".join(tags)
        priority = SOURCE_PRIORITIES.get(source, 50)

        conn.execute(
            """INSERT OR REPLACE INTO agent_entries
               (id, name, description, category, primary_phase,
                compatible_phases, tags, source, priority,
                tools, model, max_turns, body, file_path, indexed_at)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (entry_id, name, description, category, primary_phase,
             phases_str, tags_str, source, priority,
             "", "", 0, body, "registered:%s" % name, now),
        )

        # Update FTS
        conn.execute(
            """INSERT OR REPLACE INTO agent_entries_fts
               (rowid, name, description, tags, body)
               VALUES (
                   (SELECT rowid FROM agent_entries WHERE id = ?),
                   ?, ?, ?, ?
               )""",
            (entry_id, name, description, tags_str, body),
        )
        conn.commit()

        return {
            "registered": True,
            "name": name,
            "id": entry_id,
            "source": source,
        }
    finally:
        conn.close()


def do_stats(db_path: str) -> Dict[str, Any]:
    """Get summary statistics about the agent search index.

    Args:
        db_path: Path to the SQLite database.

    Returns:
        Dict with counts by source, category, phase, and metadata.
    """
    conn = get_db(db_path)
    try:
        ensure_schema(conn)

        total = conn.execute(
            "SELECT COUNT(*) FROM agent_entries"
        ).fetchone()[0]

        by_source = {}
        for row in conn.execute(
            "SELECT source, COUNT(*) AS cnt FROM agent_entries GROUP BY source"
        ).fetchall():
            by_source[row["source"]] = row["cnt"]

        by_category = {}
        for row in conn.execute(
            "SELECT category, COUNT(*) AS cnt FROM agent_entries GROUP BY category"
        ).fetchall():
            by_category[row["category"]] = row["cnt"]

        by_phase = {}
        for row in conn.execute(
            "SELECT primary_phase, COUNT(*) AS cnt "
            "FROM agent_entries WHERE primary_phase != '' "
            "GROUP BY primary_phase"
        ).fetchall():
            by_phase[row["primary_phase"]] = row["cnt"]

        last_indexed = conn.execute(
            "SELECT value FROM agent_meta WHERE key = 'last_indexed'"
        ).fetchone()

        return {
            "total_agents": total,
            "by_source": by_source,
            "by_category": by_category,
            "by_phase": by_phase,
            "last_indexed": last_indexed["value"] if last_indexed else None,
        }
    finally:
        conn.close()


def do_reindex(
    plugin_root: str,
    project_dir: str,
    db_path: str,
) -> Dict[str, Any]:
    """Re-parse all agent files and rebuild the FTS index.

    Args:
        plugin_root: Path to the Rune plugin root.
        project_dir: Path to the project root.
        db_path: Path to the SQLite database.

    Returns:
        Dict with indexing results.
    """
    from indexer import discover_and_parse

    start_ms = int(time.time() * 1000)
    entries = discover_and_parse(plugin_root, project_dir)

    conn = get_db(db_path)
    try:
        ensure_schema(conn)
        count = rebuild_index(conn, entries)
        conn.execute(
            "INSERT OR REPLACE INTO agent_meta (key, value) VALUES (?, ?)",
            ("last_indexed", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())),
        )
        conn.commit()
    finally:
        conn.close()

    elapsed_ms = int(time.time() * 1000) - start_ms
    sources = {}
    for e in entries:
        src = e.get("source", "unknown")
        sources[src] = sources.get(src, 0) + 1

    return {
        "entries_indexed": count,
        "time_ms": elapsed_ms,
        "by_source": sources,
        "total_parsed": len(entries),
    }


def _do_reindex_internal(conn: sqlite3.Connection) -> int:
    """Internal reindex using an existing connection (for auto-reindex).

    Args:
        conn: Active database connection.

    Returns:
        Number of entries indexed.
    """
    from indexer import discover_and_parse

    entries = discover_and_parse(PLUGIN_ROOT, PROJECT_DIR)
    count = rebuild_index(conn, entries)
    conn.execute(
        "INSERT OR REPLACE INTO agent_meta (key, value) VALUES (?, ?)",
        ("last_indexed", time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())),
    )
    conn.commit()
    return count


# ---------------------------------------------------------------------------
# FTS query sanitization
# ---------------------------------------------------------------------------

# FTS5 special characters that need escaping
_FTS_SPECIAL = re.compile(r'[":*^~()]')


def _sanitize_fts_query(query: str) -> str:
    """Sanitize a user query for FTS5 MATCH syntax.

    Converts natural language to OR-joined terms with prefix matching.

    Args:
        query: Raw user query string.

    Returns:
        Sanitized FTS5 query string, or empty string if invalid.
    """
    if not query or not query.strip():
        return ""

    # Remove FTS5 special characters
    cleaned = _FTS_SPECIAL.sub(" ", query)
    terms = [t.strip() for t in cleaned.split() if len(t.strip()) > 1]

    if not terms:
        return ""

    # Use OR-joined prefix matching for broad retrieval
    # FTS5 prefix: "term*" matches any token starting with "term"
    fts_terms = ['"%s"*' % t for t in terms[:10]]  # Cap at 10 terms
    return " OR ".join(fts_terms)


def _fallback_fts_query(query: str) -> str:
    """Generate a simpler fallback FTS query when the primary fails.

    Uses simple prefix matching on individual terms.

    Args:
        query: Raw user query string.

    Returns:
        Simplified FTS5 query string.
    """
    cleaned = _FTS_SPECIAL.sub(" ", query)
    terms = [t.strip() for t in cleaned.split() if len(t.strip()) > 1]
    if not terms:
        return ""
    # Single longest term as prefix
    longest = max(terms, key=len)
    return '"%s"*' % longest


# ---------------------------------------------------------------------------
# MCP tool handlers
# ---------------------------------------------------------------------------


async def _mcp_handle_search(arguments: Dict) -> Tuple[Dict, bool]:
    """Handle agent_search tool call.

    Performs hybrid BM25 + multi-factor search across agent definitions.
    Writes search-called signal for hook integration.
    """
    query = arguments.get("query", "")
    if not isinstance(query, str) or not query.strip():
        return {"error": "query parameter is required"}, True

    phase = arguments.get("phase")
    if phase is not None and not isinstance(phase, str):
        phase = None

    category = arguments.get("category")
    if category is not None and not isinstance(category, str):
        category = None

    source = arguments.get("source")
    if source is not None and not isinstance(source, str):
        source = None

    exclude = arguments.get("exclude")
    if exclude is not None:
        if isinstance(exclude, list):
            exclude = [str(e) for e in exclude if e]
        else:
            exclude = None

    limit = arguments.get("limit", 5)
    if not isinstance(limit, int):
        try:
            limit = int(limit)
        except (ValueError, TypeError):
            limit = 5

    # Write search-called signal
    _write_search_signal(PROJECT_DIR)

    result = do_search(
        DB_PATH, query,
        phase=phase, category=category,
        source=source, exclude=exclude,
        limit=limit,
    )
    return result, False


async def _mcp_handle_detail(arguments: Dict) -> Tuple[Dict, bool]:
    """Handle agent_detail tool call.

    Returns full agent frontmatter and body for a given name.
    """
    name = arguments.get("name", "")
    if not isinstance(name, str) or not name.strip():
        return {"error": "name parameter is required"}, True

    result = do_detail(DB_PATH, name.strip())
    is_error = "error" in result
    return result, is_error


async def _mcp_handle_register(arguments: Dict) -> Tuple[Dict, bool]:
    """Handle agent_register tool call.

    Registers a user/project agent definition.
    """
    name = arguments.get("name", "")
    if not isinstance(name, str) or not name.strip():
        return {"error": "name parameter is required"}, True

    description = arguments.get("description", "")
    if not isinstance(description, str):
        description = str(description)

    categories = arguments.get("categories", [])
    if not isinstance(categories, list):
        categories = [str(categories)] if categories else []

    primary_phase = arguments.get("primary_phase", "")
    if not isinstance(primary_phase, str):
        primary_phase = ""

    compatible_phases = arguments.get("compatible_phases", [])
    if not isinstance(compatible_phases, list):
        compatible_phases = []

    tags = arguments.get("tags", [])
    if not isinstance(tags, list):
        tags = []

    body = arguments.get("body", "")
    if not isinstance(body, str):
        body = ""

    source = arguments.get("source", "user")
    if not isinstance(source, str) or source not in ("user", "project"):
        source = "user"

    result = do_register(
        DB_PATH, name.strip(), description,
        categories, primary_phase, compatible_phases,
        tags, body, source,
    )
    is_error = "error" in result
    return result, is_error


async def _mcp_handle_stats(_arguments: Dict) -> Tuple[Dict, bool]:
    """Handle agent_stats tool call.

    Returns index statistics.
    """
    result = do_stats(DB_PATH)
    return result, False


async def _mcp_handle_reindex(_arguments: Dict) -> Tuple[Dict, bool]:
    """Handle agent_reindex tool call.

    Forces a full rebuild of the FTS5 index.
    """
    if not PLUGIN_ROOT:
        return {"error": "PLUGIN_ROOT not configured"}, True
    if not PROJECT_DIR:
        return {"error": "PROJECT_DIR not configured"}, True

    result = do_reindex(PLUGIN_ROOT, PROJECT_DIR, DB_PATH)
    return result, False


# Handler dispatch table
_MCP_HANDLERS = {
    "agent_search": _mcp_handle_search,
    "agent_detail": _mcp_handle_detail,
    "agent_register": _mcp_handle_register,
    "agent_stats": _mcp_handle_stats,
    "agent_reindex": _mcp_handle_reindex,
}


# ---------------------------------------------------------------------------
# MCP tool schemas
# ---------------------------------------------------------------------------

TOOL_SCHEMAS = [
    {
        "name": "agent_search",
        "description": (
            "Search for Rune agents by capability, phase, or category. "
            "Returns ranked results using hybrid BM25 + multi-factor scoring."
        ),
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
        "inputSchema": {
            "type": "object",
            "properties": {
                "query": {
                    "type": "string",
                    "description": (
                        "Search query — agent name, capability description, "
                        "or keywords (e.g., 'security review', 'dead code')"
                    ),
                },
                "phase": {
                    "type": "string",
                    "description": (
                        "Filter by workflow phase "
                        "(e.g., appraise, audit, strive, devise, arc)"
                    ),
                    "enum": [
                        "devise", "forge", "appraise", "audit", "strive",
                        "arc", "mend", "inspect", "goldmask", "debug",
                        "test-browser", "design-sync", "design-prototype",
                    ],
                },
                "category": {
                    "type": "string",
                    "description": "Filter by agent category",
                    "enum": [
                        "review", "investigation", "research",
                        "work", "utility", "testing",
                    ],
                },
                "source": {
                    "type": "string",
                    "description": "Filter by agent source",
                    "enum": ["builtin", "extended", "project", "user"],
                },
                "exclude": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Agent names to exclude from results",
                },
                "limit": {
                    "type": "integer",
                    "description": "Max results (default 5, max 20)",
                    "default": 5,
                },
            },
            "required": ["query"],
        },
    },
    {
        "name": "agent_detail",
        "description": (
            "Get full details for a specific agent by name, "
            "including frontmatter, tools, and body content."
        ),
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Agent name (e.g., 'flaw-hunter', 'ward-sentinel')",
                },
            },
            "required": ["name"],
        },
    },
    {
        "name": "agent_register",
        "description": (
            "Register a new user or project agent definition. "
            "Cannot overwrite builtin agents."
        ),
        "annotations": {
            "readOnlyHint": False,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
        "inputSchema": {
            "type": "object",
            "properties": {
                "name": {
                    "type": "string",
                    "description": "Agent name (lowercase + hyphens, max 64 chars)",
                },
                "description": {
                    "type": "string",
                    "description": "Agent description (min 10 chars)",
                },
                "categories": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Agent categories (review, investigation, etc.)",
                },
                "primary_phase": {
                    "type": "string",
                    "description": "Primary workflow phase",
                },
                "compatible_phases": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Compatible workflow phases",
                },
                "tags": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "Searchable tags",
                },
                "body": {
                    "type": "string",
                    "description": "Agent system prompt / body markdown",
                },
                "source": {
                    "type": "string",
                    "description": "Source (user or project, default user)",
                    "enum": ["user", "project"],
                    "default": "user",
                },
            },
            "required": ["name", "description"],
        },
    },
    {
        "name": "agent_stats",
        "description": "Get summary statistics of the agent search index.",
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
        "inputSchema": {
            "type": "object",
            "properties": {},
            "required": [],
        },
    },
    {
        "name": "agent_reindex",
        "description": (
            "Force rebuild the agent search FTS5 index from all source directories."
        ),
        "annotations": {
            "readOnlyHint": False,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
        "inputSchema": {
            "type": "object",
            "properties": {},
            "required": [],
        },
    },
]


# ---------------------------------------------------------------------------
# MCP Server
# ---------------------------------------------------------------------------


def _validate_mcp_env() -> None:
    """Validate environment for MCP server startup."""
    if not DB_PATH:
        print("Error: DB_PATH environment variable not set", file=sys.stderr)
        sys.exit(1)
    db_parent = os.path.dirname(DB_PATH) or "."
    if not os.path.isdir(db_parent):
        try:
            os.makedirs(db_parent, exist_ok=True)
        except OSError as exc:
            print("Error: cannot create DB_PATH parent directory: %s (%s)"
                  % (db_parent, exc), file=sys.stderr)
            sys.exit(1)
    if not os.access(db_parent, os.W_OK):
        print("Error: DB_PATH parent directory is not writable: %s" % db_parent,
              file=sys.stderr)
        sys.exit(1)


def _register_mcp_handlers(server: Any, types: Any) -> None:
    """Register list_tools and call_tool handlers on the MCP server.

    Args:
        server: MCP Server instance.
        types: MCP types module.
    """

    @server.list_tools()
    async def handle_list_tools() -> list:
        tools = []
        for s in TOOL_SCHEMAS:
            kwargs = {
                "name": s["name"],
                "description": s["description"],
                "inputSchema": s["inputSchema"],
            }
            if "annotations" in s:
                kwargs["annotations"] = types.ToolAnnotations(
                    **s["annotations"])
            tools.append(types.Tool(**kwargs))
        return tools

    @server.call_tool()
    async def handle_call_tool(
        name: str, arguments: Optional[Dict],
    ) -> list:
        try:
            handler = _MCP_HANDLERS.get(name)
            if handler is None:
                data, is_error = {"error": "Unknown tool: %s" % name}, True
            else:
                data, is_error = await handler(arguments or {})
            return [types.TextContent(
                type="text", text=json.dumps(data, indent=2),
                isError=True if is_error else None,
            )]
        except (ValueError, TypeError, KeyError, sqlite3.Error, OSError) as e:
            err_msg = str(e)[:200] if str(e) else "Internal server error"
            return [types.TextContent(
                type="text", text=json.dumps({"error": err_msg}),
                isError=True,
            )]


def run_mcp_server() -> None:
    """Launch the Agent Search MCP stdio server.

    Validates environment, imports MCP dependencies, registers handlers,
    and runs the async loop.
    """
    _validate_mcp_env()
    import asyncio
    import mcp.server.stdio
    import mcp.types as types
    from mcp.server.lowlevel import Server, NotificationOptions
    from mcp.server.models import InitializationOptions
    server = Server("agent-search")
    _register_mcp_handlers(server, types)

    async def _run() -> None:
        async with mcp.server.stdio.stdio_server() as (read_stream, write_stream):
            await server.run(
                read_stream, write_stream,
                InitializationOptions(
                    server_name="agent-search", server_version="1.0.0",
                    capabilities=server.get_capabilities(
                        notification_options=NotificationOptions(),
                        experimental_capabilities={},
                    ),
                ),
            )

    asyncio.run(_run())


# ---------------------------------------------------------------------------
# CLI entry point
# ---------------------------------------------------------------------------


def main_cli() -> None:
    """CLI entry point — run as MCP server or perform a standalone reindex."""
    parser = argparse.ArgumentParser(
        description="Agent Search MCP Server"
    )
    parser.add_argument(
        "--reindex",
        action="store_true",
        help="Reindex all agent definition files and exit",
    )
    args = parser.parse_args()

    if args.reindex:
        if not PLUGIN_ROOT:
            print("Error: PLUGIN_ROOT environment variable not set",
                  file=sys.stderr)
            sys.exit(1)
        if not PROJECT_DIR:
            print("Error: PROJECT_DIR environment variable not set",
                  file=sys.stderr)
            sys.exit(1)
        if not DB_PATH:
            print("Error: DB_PATH environment variable not set",
                  file=sys.stderr)
            sys.exit(1)

        result = do_reindex(PLUGIN_ROOT, PROJECT_DIR, DB_PATH)
        print("Indexed %d entries in %dms" % (
            result["entries_indexed"], result["time_ms"]))
        print("Sources: %s" % json.dumps(result["by_source"]))
        sys.exit(0)

    # Default: run as MCP stdio server
    run_mcp_server()


if __name__ == "__main__":
    main_cli()
