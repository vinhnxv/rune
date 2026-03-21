"""
Search operations for the echo search system.

Provides FTS5 query building, full-text search execution, detail retrieval,
and index statistics. These are the core read-path functions that the MCP
handlers call to serve echo_search, echo_details, and echo_stats requests.

FTS5 query safety: All user input is tokenized and filtered through a
stopword list before being joined with OR operators. Raw input is never
passed directly to FTS5 MATCH expressions (SEC-2, SEC-7).
"""
from __future__ import annotations

import re
import sqlite3
from typing import Any, Dict, List, Optional, Tuple

from config import STOPWORDS

logger = __import__("logging").getLogger("echo-search")

# Regex for tokenizing raw search queries into alphanumeric words.
_TOKEN_RE = re.compile(r"[a-zA-Z0-9_]+")


def build_fts_query(raw_query):
    """Convert a raw search string into a safe FTS5 MATCH expression.

    Tokenizes, strips stopwords, and joins with OR.  Returns an empty
    string when no usable tokens remain (caller should short-circuit).
    """
    # type: (str) -> str
    raw_query = raw_query[:500]  # SEC-7: cap input length
    tokens = _TOKEN_RE.findall(raw_query.lower())
    filtered = [t for t in tokens if t not in STOPWORDS and len(t) >= 2]
    if not filtered:
        filtered = [t for t in tokens if len(t) >= 2]
    if not filtered:
        return ""  # SEC-2: never pass raw input to FTS5 MATCH
    return " OR ".join(filtered[:20])  # SEC-7: cap token count


def _build_search_sql(
    fts_query: str, layer: Optional[str], role: Optional[str], limit: int,
    category: Optional[str] = None, domain: Optional[str] = None,
) -> Tuple[str, List[Any]]:
    """Build FTS5 search SQL with optional layer/role/category/domain filters."""
    sql = """SELECT e.id, e.source, e.layer, e.role, e.date,
                    substr(e.content, 1, 200) AS content_preview,
                    e.line_number, e.tags, bm25(echo_entries_fts) AS score
             FROM echo_entries_fts f
             JOIN echo_entries e ON e.rowid = f.rowid
             WHERE echo_entries_fts MATCH ? AND e.archived = 0"""
    params = [fts_query]  # type: List[Any]
    if layer:
        sql += " AND e.layer = ?"
        params.append(layer)
    if role:
        sql += " AND e.role = ?"
        params.append(role)
    if category:
        sql += " AND e.category = ?"
        params.append(category)
    if domain:
        sql += " AND e.domain = ?"
        params.append(domain)
    sql += " ORDER BY bm25(echo_entries_fts) ASC LIMIT ?"
    params.append(limit)
    return sql, params


def _search_row_to_dict(row: sqlite3.Row) -> Dict[str, Any]:
    """Convert a search result row to a result dict."""
    return {
        "id": row["id"], "source": row["source"],
        "layer": row["layer"], "role": row["role"],
        "date": row["date"], "content_preview": row["content_preview"],
        "score": round(row["score"], 4),
        "line_number": row["line_number"], "tags": row["tags"],
    }


def search_entries(conn, query, limit=10, layer=None, role=None, category=None,
                   domain=None):
    """Execute a BM25 full-text search over the echo entries table."""
    # type: (sqlite3.Connection, str, int, Optional[str], Optional[str], Optional[str], Optional[str]) -> List[Dict]
    fts_query = build_fts_query(query)
    if not fts_query:
        return []
    sql, params = _build_search_sql(fts_query, layer, role, limit, category,
                                    domain)
    cursor = conn.execute(sql, params)
    return [_search_row_to_dict(row) for row in cursor.fetchall()]


def get_details(conn, ids):
    """Fetch full content for echo entries by their IDs.

    Args:
        conn: Open SQLite connection.
        ids: List of entry ID strings (capped at 100 for safety).

    Returns:
        List of entry dicts with full content and file path.
    """
    # type: (sqlite3.Connection, List[str]) -> List[Dict]
    if not ids:
        return []
    # SEC-002: Defense-in-depth cap + type validation (coerce non-strings, filter None)
    ids = [str(i) for i in ids if i is not None][:100]
    if not ids:
        return []
    placeholders = ",".join(["?"] * len(ids))
    sql = """
        SELECT id, source, layer, role, content AS full_content,
               date, tags, line_number, file_path
        FROM echo_entries
        WHERE id IN (%s)
    """ % placeholders

    cursor = conn.execute(sql, ids)
    results = []
    for row in cursor.fetchall():
        results.append({
            "id": row["id"],
            "source": row["source"],
            "layer": row["layer"],
            "role": row["role"],
            "full_content": row["full_content"],
            "date": row["date"],
            "tags": row["tags"],
            "line_number": row["line_number"],
            "file_path": row["file_path"],
        })
    return results


def _query_by_group(conn: sqlite3.Connection, column: str) -> dict:
    """Query echo_entries grouped by a column, returning {value: count}."""
    ALLOWED_COLUMNS = {"layer", "role", "category"}
    if column not in ALLOWED_COLUMNS:
        raise ValueError(f"Invalid group-by column: {column}")
    result = {}  # type: Dict[str, int]
    # Safe %-format: column is validated against ALLOWED_COLUMNS allowlist above
    for row in conn.execute(
        "SELECT %s, COUNT(*) as cnt FROM echo_entries GROUP BY %s" % (column, column)
    ):
        result[row[column] or "general"] = row["cnt"]
    return result


def _query_optional_count(conn: sqlite3.Connection, sql: str) -> int:
    """Execute a COUNT query, returning 0 on OperationalError (schema compat)."""
    try:
        return conn.execute(sql).fetchone()[0]
    except sqlite3.OperationalError:
        return 0


def get_stats(conn):
    """Return summary statistics about the echo search index.

    Returns a dict with total entry count, breakdown by layer and role,
    and the last-indexed timestamp.
    """
    # type: (sqlite3.Connection) -> Dict
    total = conn.execute("SELECT COUNT(*) FROM echo_entries").fetchone()[0]
    by_layer = _query_by_group(conn, "layer")
    by_role = _query_by_group(conn, "role")

    try:
        by_category = _query_by_group(conn, "category")
    except sqlite3.OperationalError:
        by_category = {}  # Pre-V3 schema without category column

    archived_count = _query_optional_count(
        conn, "SELECT COUNT(*) FROM echo_entries WHERE archived = 1"
    )

    last_row = conn.execute(
        "SELECT value FROM echo_meta WHERE key='last_indexed'"
    ).fetchone()

    return {
        "total_entries": total,
        "by_layer": by_layer,
        "by_role": by_role,
        "by_category": by_category,
        "archived_count": archived_count,
        "last_indexed": last_row[0] if last_row else "",
    }
