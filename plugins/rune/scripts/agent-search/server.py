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

logging.basicConfig(
    level=logging.INFO,
    format="%(name)s %(levelname)s %(message)s",
    stream=sys.stderr,
)
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
# Talisman user_agents loader
# ---------------------------------------------------------------------------


def _load_talisman_user_agents(project_dir: str) -> list:
    """Load user_agents from talisman resolved shards.

    Reads ``tmp/.talisman-resolved/settings.json`` for ``ashes.custom``
    entries that have inline agent definitions (description + body), and
    ``user_agents`` key if present in misc shard.

    Returns a list of agent definition dicts compatible with
    ``indexer.discover_and_parse(talisman_user_agents=...)``.
    """
    if not project_dir:
        return []

    agents: list = []

    # Path 1: settings.json → user_agents (dedicated key, preferred)
    settings_path = os.path.join(project_dir, "tmp", ".talisman-resolved", "settings.json")
    try:
        with open(settings_path) as f:
            settings = json.load(f)
        user_agents = settings.get("user_agents", [])
        if isinstance(user_agents, list):
            agents.extend(user_agents)
    except (OSError, ValueError):
        pass  # File missing or invalid JSON — non-fatal

    # Path 2: misc.json → user_agents (fallback location)
    if not agents:
        misc_path = os.path.join(project_dir, "tmp", ".talisman-resolved", "misc.json")
        try:
            with open(misc_path) as f:
                misc = json.load(f)
            user_agents = misc.get("user_agents", [])
            if isinstance(user_agents, list):
                agents.extend(user_agents)
        except (OSError, ValueError):
            pass

    return agents


def _load_extra_agent_dirs(project_dir: str) -> list:
    """Load extra_agent_dirs from talisman resolved shards.

    Reads ``tmp/.talisman-resolved/settings.json`` for the
    ``extra_agent_dirs`` key — a list of directory paths to scan
    for additional agent definitions.

    Returns a list of directory path strings.
    """
    if not project_dir:
        return []

    for shard_name in ("settings.json", "misc.json"):
        shard_path = os.path.join(project_dir, "tmp", ".talisman-resolved", shard_name)
        try:
            with open(shard_path) as f:
                data = json.load(f)
            dirs = data.get("extra_agent_dirs", [])
            if isinstance(dirs, list) and dirs:
                return [d for d in dirs if isinstance(d, str) and d]
        except (OSError, ValueError):
            continue

    return []


# ---------------------------------------------------------------------------
# Dirty signal helpers (consumed from annotate-dirty.sh)
# ---------------------------------------------------------------------------


def _signal_path(project_dir: str) -> str:
    """Derive the dirty-signal file path from PROJECT_DIR.

    The PostToolUse hook writes the signal to
    ``<project>/tmp/.rune-signals/.agent-search-dirty``.

    Args:
        project_dir: Project root directory.

    Returns:
        Absolute path to the dirty signal file, or empty string.
    """
    if not project_dir:
        return ""
    # SEC-007: Re-canonicalize to prevent path traversal
    real_dir = os.path.realpath(project_dir)
    return os.path.join(real_dir, "tmp", ".rune-signals", ".agent-search-dirty")


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
        os.remove(path)
        return True
    except FileNotFoundError:
        pass  # Signal was already consumed by another process
    except OSError:
        pass  # Permission issue or other OS error — safe to ignore
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

# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

SCHEMA_VERSION = 2


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
    if current < 2:
        _migrate_v2(conn)

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


def _migrate_v2(conn: sqlite3.Connection) -> None:
    """Apply V2 schema: add languages column and rebuild FTS5 with languages.

    SEC-WARD-002 FIX: Uses BEGIN EXCLUSIVE to serialize concurrent startup.
    BACK-P1-001 NOTE: After migration, existing agents have languages=''.
    A full reindex (agent_reindex) is needed to populate languages from
    frontmatter. The dirty signal auto-reindex handles this on next search.
    """
    # SEC-WARD-002: Serialize DDL with exclusive transaction
    conn.execute("BEGIN EXCLUSIVE")
    try:
        # Add languages column to agent_entries (idempotent)
        try:
            conn.execute(
                "ALTER TABLE agent_entries ADD COLUMN languages TEXT DEFAULT ''"
            )
        except sqlite3.OperationalError:
            pass  # Column already exists

        # Drop and recreate FTS5 table with languages column
        conn.execute("DROP TABLE IF EXISTS agent_entries_fts")
        conn.execute("""CREATE VIRTUAL TABLE agent_entries_fts USING fts5(
            name, description, tags, languages, body,
            content=agent_entries,
            tokenize='porter unicode61'
        )""")

        # Repopulate FTS from existing data
        conn.execute("""INSERT INTO agent_entries_fts
            (rowid, name, description, tags, languages, body)
            SELECT rowid, name, description, tags, languages, body
            FROM agent_entries""")

        conn.execute("COMMIT")
    except (sqlite3.OperationalError, sqlite3.IntegrityError, sqlite3.DatabaseError):
        conn.execute("ROLLBACK")
        raise


def _clear_index(conn: sqlite3.Connection) -> None:
    """Clear all rows from agent_entries and FTS tables."""
    conn.execute("DELETE FROM agent_entries")
    conn.execute("DELETE FROM agent_entries_fts")


def _insert_entries(
    conn: sqlite3.Connection,
    sorted_entries: List[Dict[str, Any]],
    now: str,
) -> Tuple[int, int]:
    """Insert agent entries using bulk operations (PERF-009).

    Assumes the index has been cleared first (via _clear_index).  Deduplicates
    within the batch using priority-aware resolution in Python, then uses
    executemany() for bulk INSERT and a single INSERT ... SELECT for FTS sync.

    Returns:
        Tuple of (count_indexed, count_skipped).
    """
    # Within-batch dedup: since tables are cleared before insert, we only need
    # to resolve priority conflicts within the current batch.
    # sorted_entries is already sorted by priority ASC, so later (higher
    # priority) entries overwrite earlier ones in the dict.
    deduped: Dict[str, Dict[str, Any]] = {}
    skipped = 0
    for entry in sorted_entries:
        name = entry.get("name", "")
        if not name:
            continue
        prev = deduped.get(name)
        if prev and prev.get("priority", 50) > entry.get("priority", 50):
            logger.debug(
                "Skipping '%s' (source=%s, p%d) — higher-priority entry in batch",
                name, entry.get("source", "builtin"), entry.get("priority", 50),
            )
            skipped += 1
            continue
        if prev:
            skipped += 1  # the previous lower-priority entry is being replaced
        deduped[name] = entry

    # Prepare rows for bulk INSERT
    rows = []
    for entry in deduped.values():
        rows.append((
            entry.get("id", ""),
            entry.get("name", ""),
            entry.get("description", ""),
            entry.get("category", "unknown"),
            entry.get("primary_phase", ""),
            ",".join(entry.get("compatible_phases", [])),
            ",".join(entry.get("tags", [])),
            ",".join(entry.get("languages", [])),
            entry.get("source", "builtin"),
            entry.get("priority", 50),
            ",".join(str(t) for t in entry.get("tools", [])),
            entry.get("model", ""),
            entry.get("max_turns", 0),
            entry.get("body", ""),
            entry.get("file_path", ""),
            now,
        ))

    # Bulk INSERT all entries (PERF-009)
    conn.executemany(
        """INSERT OR REPLACE INTO agent_entries
           (id, name, description, category, primary_phase,
            compatible_phases, tags, languages, source, priority,
            tools, model, max_turns, body, file_path, indexed_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        rows,
    )

    # Single FTS rebuild from inserted entries (content= table requires
    # manual sync, but we can do it in one INSERT ... SELECT)
    conn.execute(
        """INSERT INTO agent_entries_fts
               (rowid, name, description, tags, languages, body)
           SELECT rowid, name, description, tags, languages, body
           FROM agent_entries"""
    )

    count = len(rows)
    return count, skipped


def rebuild_index(
    conn: sqlite3.Connection,
    entries: List[Dict[str, Any]],
) -> int:
    """Rebuild the full-text search index from parsed agent entries.

    Drops and recreates all rows.  FTS sync is done manually via
    INSERT...SELECT (external content table, not automatic triggers).

    Runs inside an explicit transaction for crash safety.

    Args:
        conn: Active database connection.
        entries: List of agent entry dicts from indexer.discover_and_parse().

    Returns:
        Number of entries indexed.
    """
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())

    conn.execute("BEGIN")
    try:
        _clear_index(conn)

        # DES-001 FIX: Sort entries by priority ASCENDING so that higher-priority
        # agents are inserted LAST and win INSERT OR REPLACE conflicts.
        # Without this, builtin (p100) inserted first gets overwritten by user (p50).
        sorted_entries = sorted(entries, key=lambda e: e.get("priority", 50))

        count, skipped = _insert_entries(conn, sorted_entries, now)

        conn.commit()
    except (sqlite3.Error, OSError):
        conn.rollback()
        raise
    if skipped:
        logger.info("rebuild_index: %d indexed, %d skipped (priority conflicts)", count, skipped)
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
# Core operations — helpers
# ---------------------------------------------------------------------------


def _build_search_query(
    fts_query: str,
    category: Optional[str],
    source: Optional[str],
    language: Optional[str],
    fetch_limit: int,
) -> Tuple[str, List[Any]]:
    """Build FTS5 SQL query with optional filter clauses."""
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
    if language:
        # Comma-delimited matching: wrap stored value in commas to avoid
        # substring false positives (e.g., 'go' matching 'golang').
        # Parameterized query prevents SQL injection.
        # SEC-WARD-001 FIX: Escape LIKE wildcards (% and _) in user input
        safe_lang = language.lower().replace("%", "\\%").replace("_", "\\_")
        sql += " AND (',' || e.languages || ',' LIKE ? ESCAPE '\\')"
        params.append("%," + safe_lang + ",%")

    sql += " ORDER BY bm25(agent_entries_fts) LIMIT ?"
    params.append(fetch_limit)

    return sql, params


def _execute_search_query(
    conn: sqlite3.Connection,
    sql: str,
    params: List[Any],
    query: str,
) -> List[Dict[str, Any]]:
    """Execute FTS5 query with fallback to prefix search on syntax error."""
    try:
        rows = conn.execute(sql, params).fetchall()
    except sqlite3.OperationalError as exc:
        # FTS5 query syntax error — try plain prefix search
        logger.debug("FTS5 query failed, trying prefix: %s", exc)
        fts_query = _fallback_fts_query(query)
        if not fts_query:
            return []
        params[0] = fts_query
        rows = conn.execute(sql, params).fetchall()

    return [dict(row) for row in rows]


def _score_and_rank_results(
    results: List[Dict[str, Any]],
    query: str,
    phase: Optional[str],
    category: Optional[str],
    exclude: Optional[List[str]],
    limit: int,
) -> Tuple[List[Dict[str, Any]], int]:
    """Apply exclusions, composite scoring, and trim to limit."""
    # Apply exclusions
    if exclude:
        exclude_set = set(n.lower() for n in exclude)
        results = [r for r in results if r.get("name", "").lower() not in exclude_set]

    # Re-rank with composite scoring
    results = compute_composite_score(results, query, phase, category)

    # Trim to requested limit
    total = len(results)
    results = results[:limit]

    return results, total


def _format_search_results(results: List[Dict[str, Any]]) -> None:
    """Clean up results for output — remove body, parse CSV fields to lists."""
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
        # Parse languages back to list
        langs_str = r.get("languages", "")
        if isinstance(langs_str, str):
            r["languages"] = [l.strip() for l in langs_str.split(",") if l.strip()]


# ---------------------------------------------------------------------------
# Core operations — do_search helpers
# ---------------------------------------------------------------------------


def _handle_dirty_reindex(conn: sqlite3.Connection) -> None:
    # Check for dirty signal and reindex if needed
    # FLAW-002 FIX: Use BEGIN IMMEDIATE to serialize concurrent reindex
    # attempts and prevent readers from seeing empty tables mid-rebuild
    if _check_and_clear_dirty(PROJECT_DIR):
        logger.info("Dirty signal detected — triggering auto-reindex")
        conn.execute("BEGIN IMMEDIATE")
        try:
            _do_reindex_internal(conn)
        except (sqlite3.OperationalError, sqlite3.IntegrityError, sqlite3.DatabaseError):
            conn.rollback()
            raise


def _run_search_pipeline(
    conn: sqlite3.Connection,
    query: str,
    phase: Optional[str],
    category: Optional[str],
    source: Optional[str],
    language: Optional[str],
    exclude: Optional[List[str]],
    limit: int,
) -> Optional[Tuple[List[Dict[str, Any]], int]]:
    ensure_schema(conn)
    _handle_dirty_reindex(conn)

    # Build FTS5 query — sanitize for safety
    fts_query = _sanitize_fts_query(query)
    if not fts_query:
        return None

    # Execute BM25 search with broader fetch for re-ranking
    fetch_limit = min(limit * 3, 60)  # Fetch 3x for re-ranking headroom

    sql, params = _build_search_query(fts_query, category, source, language, fetch_limit)
    results = _execute_search_query(conn, sql, params, query)

    results, total = _score_and_rank_results(results, query, phase, category, exclude, limit)
    _format_search_results(results)
    return results, total


def _build_search_response(
    results: List[Dict[str, Any]],
    total: int,
    query: str,
    phase: Optional[str],
    category: Optional[str],
    source: Optional[str],
    language: Optional[str],
    exclude: Optional[List[str]],
    elapsed_ms: int,
) -> Dict[str, Any]:
    return {
        "results": results,
        "total": total,
        "query": query,
        "filters": {
            "phase": phase,
            "category": category,
            "source": source,
            "language": language,
            "exclude": exclude or [],
        },
        "time_ms": elapsed_ms,
    }


# ---------------------------------------------------------------------------
# Core operations
# ---------------------------------------------------------------------------

def do_search(
    db_path: str,
    query: str,
    phase: Optional[str] = None,
    category: Optional[str] = None,
    source: Optional[str] = None,
    language: Optional[str] = None,
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
        language: Optional language filter (e.g., 'python', 'ruby').
        exclude: Optional list of agent names to exclude.
        limit: Maximum results to return (default 5, max 20).

    Returns:
        Dict with 'results', 'total', 'query', and timing info.
    """
    start_ms = int(time.time() * 1000)
    limit = max(1, min(limit, 20))

    conn = get_db(db_path)
    try:
        pipeline_result = _run_search_pipeline(
            conn, query, phase, category, source, language, exclude, limit,
        )
    finally:
        conn.close()

    if pipeline_result is None:
        return {"results": [], "total": 0, "query": query, "time_ms": 0}

    results, total = pipeline_result
    elapsed_ms = int(time.time() * 1000) - start_ms
    return _build_search_response(
        results, total, query, phase, category, source, language, exclude, elapsed_ms,
    )


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
        for field in ("compatible_phases", "tags", "tools", "languages"):
            val = result.get(field, "")
            if isinstance(val, str):
                result[field] = [v.strip() for v in val.split(",") if v.strip()]
        # SEC-005: Normalize file_path to relative path to avoid leaking
        # absolute filesystem paths to the client
        if "file_path" in result and result["file_path"] and PLUGIN_ROOT:
            result["file_path"] = result["file_path"].replace(
                PLUGIN_ROOT + "/", "")
        return result
    finally:
        conn.close()


def _validate_registration(
    name: str, description: str, source: str,
) -> Optional[Dict[str, Any]]:
    from schema import validate_agent_schema
    errors = validate_agent_schema(
        name=name,
        description=description,
        source=source,
    )
    if errors:
        logger.warning("Registration validation failed for '%s': %s", name, errors)
        return {"error": "Validation failed", "details": errors}
    return None


def _check_builtin_conflict(
    conn: sqlite3.Connection, name: str,
) -> Optional[Dict[str, Any]]:
    # Check for builtin/extended conflict — protect higher-priority sources
    existing = conn.execute(
        "SELECT source, priority FROM agent_entries WHERE name = ?",
        (name,),
    ).fetchone()
    if existing and existing["source"] in ("builtin", "extended"):
        return {
            "error": "Cannot overwrite %s agent: %s" % (existing["source"], name),
            "hint": "Use a different name or register as a project agent",
        }
    return None


def _prepare_registration_entry(
    name: str,
    source: str,
    categories: List[str],
    compatible_phases: List[str],
    tags: List[str],
    languages: Optional[List[str]],
) -> Dict[str, Any]:
    from indexer import generate_id, SOURCE_PRIORITIES
    return {
        "entry_id": generate_id(name, source, "registered:%s" % name),
        "now": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
        "category": categories[0] if categories else "unknown",
        "phases_str": ",".join(compatible_phases),
        "tags_str": ",".join(tags),
        # BACK-P2-001 FIX: Support languages in registration
        "languages_str": ",".join(
            lang.strip().lower()[:50] for lang in (languages or [])
            if isinstance(lang, str) and lang.strip()
        ),
        "priority": SOURCE_PRIORITIES.get(source, 50),
    }


def _write_agent_entry(
    conn: sqlite3.Connection,
    entry: Dict[str, Any],
    name: str,
    description: str,
    primary_phase: str,
    source: str,
    body: str,
) -> None:
    # Fix BACK-002: Delete old FTS entry before re-registration to prevent ghost entries
    old_row = conn.execute("SELECT rowid FROM agent_entries WHERE name = ?", (name,)).fetchone()
    if old_row:
        conn.execute("DELETE FROM agent_entries_fts WHERE rowid = ?", (old_row[0],))

    conn.execute(
        """INSERT OR REPLACE INTO agent_entries
           (id, name, description, category, primary_phase,
            compatible_phases, tags, languages, source, priority,
            tools, model, max_turns, body, file_path, indexed_at)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        (entry["entry_id"], name, description, entry["category"], primary_phase,
         entry["phases_str"], entry["tags_str"], entry["languages_str"], source,
         entry["priority"], "", "", 0, body, "registered:%s" % name, entry["now"]),
    )

    # Update FTS
    conn.execute(
        """INSERT INTO agent_entries_fts
           (rowid, name, description, tags, languages, body)
           VALUES (
               (SELECT rowid FROM agent_entries WHERE id = ?),
               ?, ?, ?, ?, ?
           )""",
        (entry["entry_id"], name, description, entry["tags_str"],
         entry["languages_str"], body),
    )
    conn.commit()


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
    languages: Optional[List[str]] = None,
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
    validation_error = _validate_registration(name, description, source)
    if validation_error:
        return validation_error

    conn = get_db(db_path)
    try:
        ensure_schema(conn)

        conflict = _check_builtin_conflict(conn, name)
        if conflict:
            return conflict

        entry = _prepare_registration_entry(
            name, source, categories, compatible_phases, tags, languages,
        )
        _write_agent_entry(conn, entry, name, description, primary_phase, source, body)

        logger.info("Registered agent '%s' (source=%s, id=%s)", name, source, entry["entry_id"])
        return {
            "registered": True,
            "name": name,
            "id": entry["entry_id"],
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

    logger.info("Reindexing agent registry from %s", plugin_root)
    start_ms = int(time.time() * 1000)
    talisman_agents = _load_talisman_user_agents(project_dir)
    extra_dirs = _load_extra_agent_dirs(project_dir)
    entries = discover_and_parse(plugin_root, project_dir, talisman_agents, extra_dirs)

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

    logger.info(
        "Reindex complete: %d entries indexed (%d parsed) in %dms — %s",
        count, len(entries), elapsed_ms, sources,
    )
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

    talisman_agents = _load_talisman_user_agents(PROJECT_DIR)
    extra_dirs = _load_extra_agent_dirs(PROJECT_DIR)
    entries = discover_and_parse(PLUGIN_ROOT, PROJECT_DIR, talisman_agents, extra_dirs)
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

# FTS5 special characters and operators that need escaping
# SEC-001: Include column filter (:), grouping ({}), boost/exclude (+-)
# and backslash to prevent query injection
_FTS_SPECIAL = re.compile(r'[":*^~(){}+\-:\\]')

# FTS5 boolean keywords that must be filtered from user queries
_FTS_BOOLEAN_KEYWORDS = frozenset({"AND", "OR", "NOT", "NEAR"})


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
    # SEC-001: Filter FTS5 boolean keywords to prevent semantic manipulation
    terms = [t.strip() for t in cleaned.split()
             if len(t.strip()) > 1 and t.strip().upper() not in _FTS_BOOLEAN_KEYWORDS]

    if not terms:
        return ""

    # SEC-005: Defensive check — verify sanitizer output contains only safe characters
    if not all(t.replace("_", "").replace("-", "").isalnum() for t in terms):
        raise ValueError("Unsanitized FTS term detected after sanitization")

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
    terms = [t.strip() for t in cleaned.split()
             if len(t.strip()) > 1 and t.strip().upper() not in _FTS_BOOLEAN_KEYWORDS]
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

    # SEC-004: Enforce query length limit before FTS processing
    if len(query) > 1000:
        return {"error": "query exceeds 1000 character limit"}, True

    phase = arguments.get("phase")
    if phase is not None and not isinstance(phase, str):
        phase = None

    category = arguments.get("category")
    if category is not None and not isinstance(category, str):
        category = None

    source = arguments.get("source")
    if source is not None and not isinstance(source, str):
        source = None

    language = arguments.get("language")
    if language is not None and not isinstance(language, str):
        language = None

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
        source=source, language=language,
        exclude=exclude, limit=limit,
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
                "language": {
                    "type": "string",
                    "description": (
                        "Filter by programming language "
                        "(e.g., 'python', 'ruby', 'typescript')"
                    ),
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
                    "description": "Agent description (min 20 chars for user agents)",
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
            # SEC-003: Log details server-side, return generic message to client
            logger.error("Tool '%s' failed: %s", name, e, exc_info=True)
            return [types.TextContent(
                type="text", text=json.dumps({"error": "Internal server error"}),
                isError=True,
            )]


def _startup_index_if_empty(db_path: str) -> None:
    """Build the FTS5 index on server startup if the database is empty.

    This prevents the chicken-and-egg problem where dirty-signal auto-reindex
    only triggers on the next search call, but no one searches because the
    index is empty — leaving workflows without agent discovery indefinitely.

    Runs synchronously before the MCP event loop starts. Typically completes
    in <100ms for ~110 agents.
    """
    if not db_path or not PLUGIN_ROOT or not PROJECT_DIR:
        return

    try:
        conn = get_db(db_path)
        try:
            ensure_schema(conn)
            row = conn.execute(
                "SELECT COUNT(*) as cnt FROM agent_entries"
            ).fetchone()
            count = row["cnt"] if row else 0
            if count == 0:
                logger.info("Empty index detected at startup — building initial index")
                indexed = _do_reindex_internal(conn)
                logger.info("Startup index complete: %d agents indexed", indexed)
            else:
                logger.info("Startup check: index has %d agents — skipping rebuild", count)
        finally:
            conn.close()
    except (sqlite3.Error, OSError, ValueError) as exc:
        # Fail-forward: startup indexing failure must not prevent server launch
        logger.warning("Startup indexing failed (non-fatal): %s", exc)


def run_mcp_server() -> None:
    """Launch the Agent Search MCP stdio server.

    Validates environment, imports MCP dependencies, registers handlers,
    and runs the async loop. Performs startup indexing if the database is empty.
    """
    _validate_mcp_env()

    # Build index on startup if empty (prevents chicken-and-egg discovery bug)
    _startup_index_if_empty(DB_PATH)

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
