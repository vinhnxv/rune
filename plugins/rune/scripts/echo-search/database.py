"""Database connection management and schema migrations for Echo Search.

Provides SQLite connection helpers (WAL mode, Row factory), global DB
connection caching (lazy — zero cost when scope=project), and versioned
schema migrations (V1–V4).

Functions:
    get_db          — Open a SQLite connection with WAL mode and Row factory.
    get_global_conn — Lazily open (and cache) the global echo DB connection.
    ensure_schema   — Run forward-only migrations up to SCHEMA_VERSION.

Internal / migration helpers:
    _ensure_global_dir, _migrate_v1 .. _migrate_v4
"""

from __future__ import annotations

import logging
import os
import sqlite3
from typing import Optional

logger = logging.getLogger("echo-search")

# ---------------------------------------------------------------------------
# Imports from server (will migrate to config.py once it exists)
# ---------------------------------------------------------------------------
# Lazy import to avoid circular dependency during decomposition.
# These constants and helpers are defined in server.py today and will move
# to config.py in a later task.  We import at function-call time where
# needed, and also expose module-level references for callers that expect
# them here.

def _get_server_constants():
    """Lazy import of configuration constants from server module."""
    from server import GLOBAL_ECHO_DIR, GLOBAL_DB_PATH, _load_talisman
    return GLOBAL_ECHO_DIR, GLOBAL_DB_PATH, _load_talisman


# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

def get_db(db_path: str) -> sqlite3.Connection:
    """Open a SQLite connection with WAL mode and Row factory.

    Args:
        db_path: Absolute path to the SQLite database file.

    Returns:
        Connection with row_factory=sqlite3.Row, journal_mode=WAL,
        and busy_timeout=5000ms.
    """
    conn = sqlite3.connect(db_path)
    conn.row_factory = sqlite3.Row
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA busy_timeout=5000")
    return conn


# ---------------------------------------------------------------------------
# Global DB connection management (lazy — zero cost when scope=project)
# ---------------------------------------------------------------------------

_global_conn: Optional[sqlite3.Connection] = None


def _ensure_global_dir() -> None:
    """Create global echo directory structure if it doesn't exist."""
    GLOBAL_ECHO_DIR, _, _ = _get_server_constants()
    if not GLOBAL_ECHO_DIR:
        return
    os.makedirs(os.path.join(GLOBAL_ECHO_DIR, "doc-packs"), exist_ok=True)
    os.makedirs(os.path.join(GLOBAL_ECHO_DIR, "manifests"), exist_ok=True)


def get_global_conn() -> Optional[sqlite3.Connection]:
    """Open global DB connection lazily. Returns None if global echoes disabled.

    The connection is cached at module level and reuses the same WAL mode,
    PRAGMA settings, and schema as the project DB.  Callers should NOT
    close the returned connection — it is shared across the server lifetime.

    Respects talisman ``echoes.global.enabled`` (default: ``True``).
    When set to ``False``, returns ``None`` regardless of env vars.
    """
    global _global_conn
    GLOBAL_ECHO_DIR, GLOBAL_DB_PATH, _load_talisman = _get_server_constants()
    if not GLOBAL_ECHO_DIR or not GLOBAL_DB_PATH:
        return None
    # Check talisman echoes.global.enabled toggle
    talisman = _load_talisman()
    echoes_cfg = talisman.get("echoes", {})
    global_cfg = echoes_cfg.get("global", {}) if isinstance(echoes_cfg, dict) else {}
    if isinstance(global_cfg, dict) and global_cfg.get("enabled") is False:
        return None
    if _global_conn is None:
        try:
            _ensure_global_dir()
            _global_conn = get_db(GLOBAL_DB_PATH)
            ensure_schema(_global_conn)
        except (sqlite3.OperationalError, sqlite3.DatabaseError, OSError) as exc:
            logger.warning("get_global_conn failed: %s", exc)
            _global_conn = None
            return None
    return _global_conn


# ---------------------------------------------------------------------------
# Schema versioning and migrations
# ---------------------------------------------------------------------------

SCHEMA_VERSION = 4
assert isinstance(SCHEMA_VERSION, int) and 0 <= SCHEMA_VERSION <= 1000


def _migrate_v1(conn: sqlite3.Connection) -> None:
    """Apply V1 schema: core echo tables, access log, and FTS index."""
    conn.execute("""CREATE TABLE IF NOT EXISTS echo_entries (
        id TEXT PRIMARY KEY, role TEXT NOT NULL, layer TEXT NOT NULL,
        date TEXT, source TEXT, content TEXT NOT NULL,
        tags TEXT DEFAULT '', line_number INTEGER, file_path TEXT NOT NULL)""")
    conn.execute("CREATE TABLE IF NOT EXISTS echo_meta (key TEXT PRIMARY KEY, value TEXT)")
    conn.execute("""CREATE TABLE IF NOT EXISTS echo_access_log (
        id INTEGER PRIMARY KEY AUTOINCREMENT, entry_id TEXT NOT NULL,
        accessed_at TEXT NOT NULL, query TEXT DEFAULT '')""")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_access_log_entry_id ON echo_access_log(entry_id)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_access_log_accessed_at ON echo_access_log(accessed_at)")
    cursor = conn.execute("SELECT name FROM sqlite_master WHERE type='table' AND name='echo_entries_fts'")
    if cursor.fetchone() is None:
        conn.execute("""CREATE VIRTUAL TABLE echo_entries_fts USING fts5(
            content, tags, source, content=echo_entries, tokenize='porter unicode61')""")


def _migrate_v2(conn: sqlite3.Connection) -> None:
    """Apply V2 schema: semantic groups and search failure tracking (EDGE-011)."""
    conn.execute("""CREATE TABLE IF NOT EXISTS semantic_groups (
        group_id TEXT NOT NULL, entry_id TEXT NOT NULL,
        similarity REAL NOT NULL DEFAULT 0.0, created_at TEXT NOT NULL,
        PRIMARY KEY (group_id, entry_id),
        FOREIGN KEY (entry_id) REFERENCES echo_entries(id) ON DELETE CASCADE)""")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_semantic_groups_entry ON semantic_groups(entry_id)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_semantic_groups_group ON semantic_groups(group_id)")
    conn.execute("""CREATE TABLE IF NOT EXISTS echo_search_failures (
        id INTEGER PRIMARY KEY AUTOINCREMENT, entry_id TEXT NOT NULL,
        token_fingerprint TEXT NOT NULL, retry_count INTEGER NOT NULL DEFAULT 0,
        first_failed_at TEXT NOT NULL, last_retried_at TEXT,
        FOREIGN KEY (entry_id) REFERENCES echo_entries(id) ON DELETE CASCADE)""")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_search_failures_fingerprint ON echo_search_failures(token_fingerprint)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_search_failures_entry ON echo_search_failures(entry_id)")


def _migrate_v3(conn: sqlite3.Connection) -> None:
    """Apply V3 schema: category and archived columns."""
    try:
        conn.execute("ALTER TABLE echo_entries ADD COLUMN category TEXT DEFAULT 'general'")
    except sqlite3.OperationalError:
        pass  # Already exists
    try:
        conn.execute("ALTER TABLE echo_entries ADD COLUMN archived INTEGER DEFAULT 0")
    except sqlite3.OperationalError:
        pass  # Already exists
    conn.execute("CREATE INDEX IF NOT EXISTS idx_echo_entries_category ON echo_entries(category)")
    conn.execute("CREATE INDEX IF NOT EXISTS idx_echo_entries_archived ON echo_entries(archived)")


def _migrate_v4(conn: sqlite3.Connection) -> None:
    """Apply V4 schema: domain column for global echo domain tagging."""
    try:
        conn.execute(
            "ALTER TABLE echo_entries ADD COLUMN domain TEXT DEFAULT 'general'")
    except sqlite3.OperationalError:
        pass  # Column already exists (idempotent)
    conn.execute(
        "CREATE INDEX IF NOT EXISTS idx_echo_entries_domain"
        " ON echo_entries(domain)")


def ensure_schema(conn: sqlite3.Connection) -> None:
    """Ensure database schema is at the current version via PRAGMA user_version."""
    conn.execute("PRAGMA foreign_keys = ON")
    version = conn.execute("PRAGMA user_version").fetchone()[0]
    if version < SCHEMA_VERSION:
        conn.execute("BEGIN IMMEDIATE")
        try:
            version = conn.execute("PRAGMA user_version").fetchone()[0]
            if version < 1:
                _migrate_v1(conn)
            if version < 2:
                _migrate_v2(conn)
            if version < 3:
                _migrate_v3(conn)
            if version < 4:
                _migrate_v4(conn)
            conn.commit()
        except (sqlite3.Error, OSError):
            conn.rollback()
            raise
        # SAFE: f-string used here because SQLite PRAGMAs do not support
        # parameterized queries (? placeholders). The int() cast guarantees
        # the value is a safe integer literal — SCHEMA_VERSION is a module-level
        # constant validated by the assert above.
        # Set user_version AFTER commit — PRAGMA is not transactional in SQLite,
        # so placing it inside the transaction would persist even on rollback.
        conn.execute(f"PRAGMA user_version = {int(SCHEMA_VERSION)}")
