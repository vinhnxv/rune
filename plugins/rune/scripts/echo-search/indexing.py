"""Echo Search — Index management, retry tracking, and reindex orchestration.

Owns the FTS5 index write-path: clearing and repopulating echo_entries,
semantic-group preservation across rebuilds, auto-archiving stale entries,
token-fingerprint-based search-failure retry tracking, and the top-level
``do_reindex`` orchestrator used by both the MCP tool handler and the CLI
``--reindex`` flag.

Functions (index management):
    _insert_entries              — Clear + bulk-insert echo_entries and rebuild FTS.
    _prune_access_log            — Remove orphaned / aged access-log rows.
    _prune_search_failures       — Remove orphaned / aged search-failure rows.
    _backup_semantic_groups_to_temp  — SQL temp-table backup before DELETE cycle.
    _restore_semantic_groups_from_temp — Restore groups for surviving entries.
    _archive_stale_entries       — Mark old, unaccessed observations as archived.
    rebuild_index                — Transaction-safe full index rebuild.

Functions (retry / failure tracking):
    compute_token_fingerprint    — SHA-256 fingerprint of normalised query tokens.
    record_search_failure        — Record or increment a failure for entry+fingerprint.
    reset_failure_on_match       — Clear failure when entry is successfully matched.
    get_retry_entries            — Retrieve entries eligible for retry with score boost.
    cleanup_aged_failures        — Probabilistic cleanup of old failure records.

Functions (reindex orchestration):
    do_reindex                   — Top-level reindex: promote → parse → rebuild.

Internal helpers:
    _build_retry_sql, _row_to_retry_entry

Constants:
    _ARCHIVE_ENABLED, _ARCHIVE_MIN_AGE, _ARCHIVE_LAYERS,
    _FAILURE_MAX_RETRIES, _FAILURE_MAX_AGE_DAYS, _FAILURE_SCORE_BOOST
"""

from __future__ import annotations

import hashlib
import logging
import os
import re
import sqlite3
import time
from typing import Any, Dict, List, Optional, Tuple

from config import STOPWORDS, _in_clause

logger = logging.getLogger("echo-search")

# ---------------------------------------------------------------------------
# Index rebuild helpers
# ---------------------------------------------------------------------------


def _insert_entries(conn: sqlite3.Connection, entries: list) -> None:
    """Clear existing entries and insert new ones into echo_entries."""
    conn.execute("DELETE FROM echo_entries")
    conn.execute(
        "INSERT INTO echo_entries_fts(echo_entries_fts) VALUES('delete-all')")
    conn.executemany(
        """INSERT OR REPLACE INTO echo_entries
           (id, role, layer, date, source, content, tags,
            line_number, file_path, category, domain)
           VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
        [(entry["id"], entry["role"], entry["layer"],
          entry.get("date", ""), entry.get("source", ""),
          entry["content"], entry.get("tags", ""),
          entry.get("line_number", 0), entry["file_path"],
          entry.get("category", "general"),
          entry.get("domain", "general"))
         for entry in entries],
    )
    conn.execute(
        "INSERT INTO echo_entries_fts(echo_entries_fts) VALUES('rebuild')")


def _prune_access_log(conn: sqlite3.Connection) -> None:
    """EDGE-007 + EDGE-010: Prune orphaned and aged access log rows."""
    conn.execute("""
        DELETE FROM echo_access_log
        WHERE entry_id NOT IN (SELECT id FROM echo_entries)
    """)
    cutoff = time.strftime(
        "%Y-%m-%dT%H:%M:%SZ",
        time.gmtime(time.time() - 180 * 86400),
    )
    conn.execute(
        "DELETE FROM echo_access_log WHERE accessed_at < ?", (cutoff,))


def _prune_search_failures(conn: sqlite3.Connection) -> None:
    """EDGE-020: Cleanup aged-out and orphaned search failures."""
    failure_cutoff = time.strftime(
        "%Y-%m-%dT%H:%M:%SZ",
        time.gmtime(time.time() - 30 * 86400),
    )
    try:
        conn.execute(
            "DELETE FROM echo_search_failures WHERE first_failed_at < ?",
            (failure_cutoff,))
        conn.execute("""
            DELETE FROM echo_search_failures
            WHERE entry_id NOT IN (SELECT id FROM echo_entries)
        """)
    except sqlite3.OperationalError:
        pass  # Table may not exist yet (pre-V2 schema)


# ---------------------------------------------------------------------------
# Auto-Archive and semantic group preservation
# ---------------------------------------------------------------------------

_ARCHIVE_ENABLED = os.environ.get("ECHO_ARCHIVE_ENABLED", "true").lower() != "false"
try:
    _ARCHIVE_MIN_AGE = int(os.environ.get("ECHO_ARCHIVE_MIN_AGE", "60"))
except ValueError:
    _ARCHIVE_MIN_AGE = 60
_ARCHIVE_LAYERS = frozenset(
    l.strip().lower()
    for l in os.environ.get("ECHO_ARCHIVE_LAYERS", "observations").split(",")
    if l.strip()
)


def _backup_semantic_groups_to_temp(conn: sqlite3.Connection) -> bool:
    """Back up semantic group memberships to a SQL temp table (PERF-002).

    Uses CREATE TEMP TABLE ... AS SELECT instead of materializing rows into
    Python memory.  Returns True if the backup succeeded (table exists in the
    current schema), False otherwise (pre-V2 schema).
    """
    try:
        conn.execute("DROP TABLE IF EXISTS _sg_backup")
        conn.execute(
            "CREATE TEMP TABLE _sg_backup AS "
            "SELECT group_id, entry_id, similarity, created_at "
            "FROM semantic_groups"
        )
        return True
    except sqlite3.OperationalError:
        return False  # Pre-V2 schema


def _restore_semantic_groups_from_temp(conn: sqlite3.Connection) -> int:
    """Restore semantic group memberships from the SQL temp table (PERF-003).

    Uses a single INSERT ... SELECT filtered by entries that still exist,
    replacing the Python-side frozenset + per-row INSERT loop.
    """
    try:
        cursor = conn.execute("""
            INSERT OR IGNORE INTO semantic_groups
                (group_id, entry_id, similarity, created_at)
            SELECT group_id, entry_id, similarity, created_at
            FROM _sg_backup
            WHERE entry_id IN (SELECT id FROM echo_entries)
        """)
        restored = cursor.rowcount
    except sqlite3.OperationalError as exc:
        logger.warning("Failed to restore semantic groups from temp: %s", exc)
        restored = 0
    # Cleanup degenerate groups (fewer than 2 members)
    try:
        conn.execute("""
            DELETE FROM semantic_groups WHERE group_id IN (
                SELECT group_id FROM semantic_groups
                GROUP BY group_id HAVING COUNT(*) < 2
            )
        """)
    except sqlite3.Error as exc:
        logger.debug("Degenerate group cleanup failed: %s", exc)
    # Drop temp table
    try:
        conn.execute("DROP TABLE IF EXISTS _sg_backup")
    except sqlite3.Error:
        pass
    return restored


def _archive_stale_entries(conn: sqlite3.Connection) -> int:
    """Mark old, unaccessed entries as archived=1.

    Archive criteria:
    - Layer is in ECHO_ARCHIVE_LAYERS
    - Date is older than ECHO_ARCHIVE_MIN_AGE days
    - Zero access log entries
    - Not a member of any semantic group
    """
    if not _ARCHIVE_ENABLED:
        return 0
    cutoff = time.strftime(
        "%Y-%m-%d",
        time.gmtime(time.time() - _ARCHIVE_MIN_AGE * 86400),
    )
    try:
        placeholders = ",".join("?" for _ in _ARCHIVE_LAYERS)
        params = list(_ARCHIVE_LAYERS) + [cutoff]  # type: List[Any]
        cursor = conn.execute(
            """UPDATE echo_entries SET archived = 1
               WHERE archived = 0
                 AND layer IN (%s)
                 AND date < ?
                 AND id NOT IN (SELECT DISTINCT entry_id FROM echo_access_log)
                 AND id NOT IN (SELECT DISTINCT entry_id FROM semantic_groups)"""
            % placeholders,
            params,
        )
        return cursor.rowcount
    except sqlite3.OperationalError:
        return 0  # Pre-V3 schema


def rebuild_index(conn, entries):
    """Clear and repopulate the FTS5 index from *entries*.

    Runs inside an explicit transaction for crash safety (QUAL-3).
    Preserves semantic groups across the DELETE+INSERT cycle and
    archives stale entries afterward.

    Args:
        conn: Open SQLite connection with V3 schema.
        entries: List of parsed echo entry dicts.

    Returns:
        Number of entries inserted.
    """
    # type: (sqlite3.Connection, List[Dict]) -> int
    conn.execute("BEGIN")  # QUAL-3: explicit transaction
    try:
        has_backup = _backup_semantic_groups_to_temp(conn)
        _insert_entries(conn, entries)
        if has_backup:
            _restore_semantic_groups_from_temp(conn)
        _archive_stale_entries(conn)
        _prune_access_log(conn)
        _prune_search_failures(conn)

        now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
        conn.execute(
            "INSERT OR REPLACE INTO echo_meta (key, value) "
            "VALUES ('last_indexed', ?)", (now,))
        conn.commit()
    except (sqlite3.Error, OSError, KeyError, ValueError):
        conn.rollback()
        raise
    return len(entries)


# ---------------------------------------------------------------------------
# Failed entry retry with token fingerprinting (Task 6)
# ---------------------------------------------------------------------------

_FAILURE_MAX_RETRIES = 3
_FAILURE_MAX_AGE_DAYS = 30
_FAILURE_SCORE_BOOST = 1.2  # Used as fixed sentinel: score = -1.0 * _FAILURE_SCORE_BOOST = -1.2
                             # (BM25 scores are negative; -1.2 ranks retry entries above normal hits)


def compute_token_fingerprint(query: str) -> str:
    """Compute a stable token fingerprint for a search query.

    Uses the same tokenization as build_fts_query(): extract alphanumeric
    tokens, filter stopwords and short tokens, then sort and deduplicate.
    The sorted unique tokens are joined and hashed with SHA-256 (EDGE-016).

    Args:
        query: Raw search query string.

    Returns:
        Hex SHA-256 digest of the normalized token set. Returns empty string
        for queries with no usable tokens.
    """
    tokens = re.findall(r"[a-zA-Z0-9_]+", query.lower()[:500])
    filtered = sorted(set(t for t in tokens if t not in STOPWORDS and len(t) >= 2))
    if not filtered:
        return ""
    return hashlib.sha256(" ".join(filtered).encode("utf-8")).hexdigest()


def record_search_failure(
    conn: sqlite3.Connection,
    entry_id: str,
    token_fingerprint: str,
) -> None:
    """Record or increment a failure for entry+fingerprint (EDGE-018)."""
    if not entry_id or not token_fingerprint:
        return
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    try:
        existing = conn.execute(
            """SELECT id, retry_count FROM echo_search_failures
               WHERE entry_id = ? AND token_fingerprint = ?""",
            (entry_id, token_fingerprint),
        ).fetchone()
        if existing is None:
            conn.execute(
                """INSERT INTO echo_search_failures
                   (entry_id, token_fingerprint, retry_count, first_failed_at, last_retried_at)
                   VALUES (?, ?, 0, ?, NULL)""",
                (entry_id, token_fingerprint, now),
            )
        elif existing["retry_count"] < _FAILURE_MAX_RETRIES:
            conn.execute(
                """UPDATE echo_search_failures
                   SET retry_count = retry_count + 1, last_retried_at = ?
                   WHERE id = ?""",
                (now, existing["id"]),
            )
        # If retry_count >= MAX, don't update (entry is exhausted)
        conn.commit()
    except sqlite3.OperationalError:
        pass  # Table may not exist (pre-V2)


def reset_failure_on_match(
    conn: sqlite3.Connection,
    entry_id: str,
    token_fingerprint: str,
) -> None:
    """Reset failure tracking when an entry is successfully matched.

    Removes the failure record for the entry+fingerprint pair, allowing
    future re-discovery (EDGE-017).

    Args:
        conn: SQLite database connection.
        entry_id: The echo entry ID that was matched.
        token_fingerprint: SHA-256 hex digest of query tokens.
    """
    if not entry_id or not token_fingerprint:
        return
    try:
        conn.execute(
            """DELETE FROM echo_search_failures
               WHERE entry_id = ? AND token_fingerprint = ?""",
            (entry_id, token_fingerprint),
        )
        conn.commit()
    except sqlite3.OperationalError:
        pass  # Table may not exist (pre-V2)


def _build_retry_sql(
    token_fingerprint: str,
    matched_ids: Optional[List[str]],
) -> Tuple[str, List[Any]]:
    """Build SQL and params for retry entry retrieval."""
    age_cutoff = time.strftime(
        "%Y-%m-%dT%H:%M:%SZ",
        time.gmtime(time.time() - _FAILURE_MAX_AGE_DAYS * 86400))
    sql = """SELECT f.entry_id, e.source, e.layer, e.role, e.date,
                    substr(e.content, 1, 200) AS content_preview,
                    e.line_number, e.tags, f.retry_count
             FROM echo_search_failures f
             JOIN echo_entries e ON e.id = f.entry_id
             WHERE f.token_fingerprint = ?
               AND f.retry_count < ? AND f.first_failed_at >= ?"""
    params: List[Any] = [token_fingerprint, _FAILURE_MAX_RETRIES, age_cutoff]
    if matched_ids:
        sql += " AND f.entry_id NOT IN (%s)" % _in_clause(len(matched_ids))
        params.extend(matched_ids)
    return sql, params


def _row_to_retry_entry(row: sqlite3.Row) -> Dict[str, Any]:
    """Convert a retry failure row to a result dict with boosted score."""
    boosted_score = round(-1.0 * _FAILURE_SCORE_BOOST, 4)
    return {
        "id": row["entry_id"], "source": row["source"],
        "layer": row["layer"], "role": row["role"],
        "date": row["date"], "content_preview": row["content_preview"],
        "tags": row["tags"], "content": row["content_preview"],
        "score": boosted_score, "line_number": row["line_number"],
        "retry_source": True,
    }


def get_retry_entries(
    conn: sqlite3.Connection,
    token_fingerprint: str,
    matched_ids: Optional[List[str]] = None,
) -> List[Dict[str, Any]]:
    """Retrieve entries eligible for retry (EDGE-019 score boost)."""
    if not token_fingerprint:
        return []
    try:
        sql, params = _build_retry_sql(token_fingerprint, matched_ids)
        cursor = conn.execute(sql, params)
        return [_row_to_retry_entry(row) for row in cursor.fetchall()]
    except sqlite3.OperationalError:
        return []  # Table may not exist (pre-V2)


def cleanup_aged_failures(conn: sqlite3.Connection) -> int:
    """Remove search failure entries older than 30 days.

    Probability-based: called from search handler with 1% chance to
    avoid running on every query (EDGE-020). Also called unconditionally
    during reindex.

    Args:
        conn: SQLite database connection.

    Returns:
        Number of rows deleted.
    """
    cutoff = time.strftime(
        "%Y-%m-%dT%H:%M:%SZ",
        time.gmtime(time.time() - _FAILURE_MAX_AGE_DAYS * 86400),
    )
    try:
        cursor = conn.execute(
            "DELETE FROM echo_search_failures WHERE first_failed_at < ?",
            (cutoff,),
        )
        conn.commit()
        return cursor.rowcount
    except sqlite3.OperationalError:
        return 0  # Table may not exist (pre-V2)


# ---------------------------------------------------------------------------
# Reindex helper (used by both CLI and MCP tool)
# ---------------------------------------------------------------------------


def do_reindex(echo_dir: str, db_path: str) -> Dict[str, Any]:
    """Re-parse MEMORY.md files, auto-promote Observations, rebuild FTS index."""
    from indexer import discover_and_parse
    from promotion import check_promotions
    from database import get_db, ensure_schema

    start_ms = int(time.time() * 1000)

    # Auto-promote eligible Observations to Inscribed BEFORE parsing.
    # This ensures promoted entries are indexed with their new layer name.
    promotions = check_promotions(echo_dir, db_path)

    entries = discover_and_parse(echo_dir)
    conn = get_db(db_path)
    try:
        ensure_schema(conn)
        count = rebuild_index(conn, entries)
    finally:
        conn.close()
    elapsed_ms = int(time.time() * 1000) - start_ms

    roles = sorted(set(e["role"] for e in entries))

    result = {
        "entries_indexed": count,
        "time_ms": elapsed_ms,
        "roles": roles,
    }  # type: Dict[str, Any]
    if promotions > 0:
        result["observations_promoted"] = promotions

    return result
