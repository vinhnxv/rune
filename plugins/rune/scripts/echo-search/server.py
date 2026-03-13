"""
Echo Search MCP Server

A Model Context Protocol (MCP) stdio server that provides full-text search
over the Rune plugin's echo system (persistent learnings stored in
.claude/echoes/<role>/MEMORY.md files).

Provides 6 tools:
  - echo_search:        BM25 full-text search with composite re-ranking
  - echo_details:       Fetch full content for specific entry IDs
  - echo_reindex:       Re-parse all MEMORY.md files and rebuild the FTS index
  - echo_stats:         Summary statistics of the echo index
  - echo_record_access: Manually record access events for entries
  - echo_upsert_group:  Create or update semantic groups

Environment variables:
  ECHO_DIR  - Path to the echoes directory (e.g., .claude/echoes)
  DB_PATH   - Path to the SQLite database file
  ECHO_WEIGHT_RELEVANCE   - BM25 relevance weight (default 0.30)
  ECHO_WEIGHT_IMPORTANCE  - Layer importance weight (default 0.30)
  ECHO_WEIGHT_RECENCY     - Recency weight (default 0.20)
  ECHO_WEIGHT_PROXIMITY   - File proximity weight (default 0.10)
  ECHO_WEIGHT_FREQUENCY   - Access frequency weight (default 0.10)

Usage:
  # As MCP stdio server (normal mode):
  python3 server.py

  # Standalone reindex:
  python3 server.py --reindex
"""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import math
import os
import re
import sqlite3
import sys
import tempfile
import time
import uuid
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

logger = logging.getLogger("echo-search")

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

ECHO_DIR = os.environ.get("ECHO_DIR", "")
DB_PATH = os.environ.get("DB_PATH", "")

# SEC-001/SEC-003: Validate env vars don't point to system or sensitive directories
_FORBIDDEN_PREFIXES = (
    "/etc", "/usr", "/bin", "/sbin", "/var/run", "/proc", "/sys",
    os.path.expanduser("~/.ssh"),
    os.path.expanduser("~/.gnupg"),
    os.path.expanduser("~/.aws"),
)
for _env_name, _env_val in [("ECHO_DIR", ECHO_DIR), ("DB_PATH", DB_PATH)]:
    if _env_val:
        _resolved = os.path.realpath(_env_val)
        if any(_resolved.startswith(p) for p in _FORBIDDEN_PREFIXES):
            print(
                "Error: %s points to system directory: %s" % (_env_name, _resolved),
                file=sys.stderr,
            )
            sys.exit(1)
# SEC-003 FIX: Allowlist validation for ECHO_DIR — must be under user home,
# project dir, or system temp. Prevents reading from arbitrary locations.
if ECHO_DIR:
    _echo_resolved = os.path.realpath(ECHO_DIR)
    _home = os.path.expanduser("~")
    _cwd = os.path.realpath(os.getcwd())
    _tmpdir = os.path.realpath(os.environ.get("TMPDIR", "/tmp"))
    _allowed_echo_prefixes = (_home, _cwd, _tmpdir)
    if not any(_echo_resolved.startswith(p) for p in _allowed_echo_prefixes):
        print(
            "Error: ECHO_DIR must be under home, project, or temp directory: %s"
            % _echo_resolved,
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
    # SEC-007 FIX: Allowlist DB_PATH parent directory — must be under user home,
    # project dir, or system temp. Prevents writes to arbitrary locations.
    _db_parent = os.path.dirname(_db_resolved)
    _home = os.path.expanduser("~")
    _cwd = os.path.realpath(os.getcwd())
    _tmpdir = os.path.realpath(os.environ.get("TMPDIR", "/tmp"))
    _allowed_prefixes = (_home, _cwd, _tmpdir)
    if not any(_db_parent.startswith(p) for p in _allowed_prefixes):
        print(
            "Error: DB_PATH must be under home, project, or temp directory: %s"
            % _db_resolved,
            file=sys.stderr,
        )
        sys.exit(1)

# Global echo store — cross-project knowledge + doc packs (lazy, optional)
GLOBAL_ECHO_DIR = os.environ.get("GLOBAL_ECHO_DIR", "")
GLOBAL_DB_PATH = os.environ.get("GLOBAL_DB_PATH", "")

# Validate global env vars through the same security checks as project vars
for _env_name, _env_val in [("GLOBAL_ECHO_DIR", GLOBAL_ECHO_DIR),
                             ("GLOBAL_DB_PATH", GLOBAL_DB_PATH)]:
    if _env_val:
        _resolved = os.path.realpath(_env_val)
        if any(_resolved.startswith(p) for p in _FORBIDDEN_PREFIXES):
            print(
                "Error: %s points to system directory: %s"
                % (_env_name, _resolved),
                file=sys.stderr,
            )
            sys.exit(1)

if GLOBAL_ECHO_DIR:
    _global_echo_resolved = os.path.realpath(GLOBAL_ECHO_DIR)
    _home = os.path.expanduser("~")
    _tmpdir = os.path.realpath(os.environ.get("TMPDIR", "/tmp"))
    if not any(_global_echo_resolved.startswith(p)
               for p in (_home, _tmpdir)):
        print(
            "Error: GLOBAL_ECHO_DIR must be under home or temp directory: %s"
            % _global_echo_resolved,
            file=sys.stderr,
        )
        sys.exit(1)

if GLOBAL_DB_PATH:
    _gdb_resolved = os.path.realpath(GLOBAL_DB_PATH)
    if not (_gdb_resolved.endswith(".db") or _gdb_resolved.endswith(".sqlite")):
        print(
            "Error: GLOBAL_DB_PATH must end with .db or .sqlite: %s"
            % _gdb_resolved,
            file=sys.stderr,
        )
        sys.exit(1)
    # SEC-003 FIX: Allowlist GLOBAL_DB_PATH parent directory — must be under
    # user home or system temp (matching DB_PATH allowlist pattern).
    _gdb_parent = os.path.dirname(_gdb_resolved)
    _home = os.path.expanduser("~")
    _tmpdir = os.path.realpath(os.environ.get("TMPDIR", "/tmp"))
    if not any(_gdb_parent.startswith(p) for p in (_home, _tmpdir)):
        print(
            "Error: GLOBAL_DB_PATH must be under home or temp directory: %s"
            % _gdb_resolved,
            file=sys.stderr,
        )
        sys.exit(1)

STOPWORDS = frozenset([
    "a", "an", "and", "are", "as", "at", "be", "but", "by", "for",
    "from", "had", "has", "have", "he", "her", "his", "i", "in",
    "is", "it", "its", "my", "not", "of", "on", "or", "our", "she",
    "so", "that", "the", "their", "them", "then", "there", "these",
    "they", "this", "to", "us", "was", "we", "what", "when", "which",
    "who", "will", "with", "you", "your",
])

# ---------------------------------------------------------------------------
# SQL helpers
# ---------------------------------------------------------------------------


def _in_clause(count):
    # type: (int) -> str
    """Build a parameterized IN-clause placeholder string.

    Returns a string like ``?,?,?`` for *count* parameters.
    SAFE: The output contains only literal ``?`` characters — never
    user-supplied data — so %-formatting the result into SQL is
    equivalent to parameterized queries.
    """
    return ",".join(["?"] * count)


# ---------------------------------------------------------------------------
# Dirty signal helpers (consumed from annotate-hook.sh)
# ---------------------------------------------------------------------------

# The PostToolUse hook (annotate-hook.sh) writes a sentinel file when a
# MEMORY.md is edited.  Before each search we check for this file and
# trigger a reindex so new echoes appear immediately in results.

_SIGNAL_SUFFIX = os.path.join(".claude", "echoes")


def _signal_path(echo_dir):
    # type: (str) -> str
    """Derive the dirty-signal file path from ECHO_DIR.

    ECHO_DIR is ``<project>/.claude/echoes``.  The hook writes the signal to
    ``<project>/tmp/.rune-signals/.echo-dirty``.
    """
    if not echo_dir:
        return ""
    # Strip /.claude/echoes (or .claude/echoes) suffix to get project root
    normalized = echo_dir.rstrip(os.sep)
    if normalized.endswith(_SIGNAL_SUFFIX):
        project_root = normalized[: -len(_SIGNAL_SUFFIX)].rstrip(os.sep)
    else:
        # Fallback: walk up two directories
        project_root = os.path.dirname(os.path.dirname(normalized))
    # SEC-007: Re-canonicalize derived project root to prevent path traversal
    project_root = os.path.realpath(project_root)
    return os.path.join(project_root, "tmp", ".rune-signals", ".echo-dirty")


def _check_and_clear_dirty(echo_dir):
    # type: (str) -> bool
    """Return True (and delete the file) if the dirty signal is present."""
    path = _signal_path(echo_dir)
    if not path:
        return False
    try:
        if os.path.isfile(path):
            os.remove(path)
            return True
    except OSError:
        pass  # Race with another consumer or permission issue — safe to ignore
    return False


# ---------------------------------------------------------------------------
# Composite scoring — 5-factor re-ranking
# ---------------------------------------------------------------------------
#
# After BM25 retrieval, results are re-scored using a weighted blend of:
#   1. Relevance  — normalized BM25 score (0.0–1.0)
#   2. Importance — layer-based weight (Etched > Inscribed > Traced)
#   3. Recency    — exponential decay based on entry age
#   4. Proximity  — file proximity to current context (evidence path extraction)
#   5. Frequency  — access frequency from echo_access_log (log-scaled)
#
# BM25 sign convention: SQLite FTS5 bm25() returns NEGATIVE values where
# more negative = more relevant. We normalize via min-max scaling:
#   normalized = (bm25_max - bm25_i) / (bm25_max - bm25_min)
# This inverts the sign so 1.0 = most relevant, 0.0 = least relevant.
# The log(1+count) formula for frequency scoring uses a logarithmic scale
# to prevent high-access entries from dominating — diminishing returns
# after the first few accesses.

# Default weights — overridable via environment variables (C4 concern:
# server.py does NOT read talisman.yml; weights come from env vars only).
_DEFAULT_WEIGHTS = {
    "relevance": 0.30,
    "importance": 0.30,
    "recency": 0.20,
    "proximity": 0.10,
    "frequency": 0.10,
}

# Layer importance mapping — higher = more important
_LAYER_IMPORTANCE = {
    "etched": 1.0,
    "notes": 0.8,
    "inscribed": 0.6,
    "observations": 0.4,
    "traced": 0.3,
}

# Recency half-life in days — entries older than this get < 0.5 score
_RECENCY_HALF_LIFE_DAYS = 30.0

# Layer-aware decay: per-layer half-life defaults (days).
# Etched = permanent (infinite half-life), Notes = slow decay, etc.
_LAYER_HALF_LIFE_DAYS = {
    "etched": float("inf"),
    "notes": 180.0,
    "inscribed": 90.0,
    "observations": 45.0,
    "traced": 30.0,
}

# Layer-aware decay env var config
_DECAY_ENABLED = os.environ.get("ECHO_DECAY_ENABLED", "true").lower() != "false"
_RECENCY_FLOOR = float(os.environ.get("ECHO_RECENCY_FLOOR", "0.1"))
_ACCESS_BOOST_DAYS = float(os.environ.get("ECHO_ACCESS_BOOST_DAYS", "15.0"))

# Override per-layer half-lives via env vars
for _lyr, _env_suffix in [
    ("etched", "ETCHED"), ("notes", "NOTES"), ("inscribed", "INSCRIBED"),
    ("observations", "OBSERVATIONS"), ("traced", "TRACED"),
]:
    _env_val = os.environ.get("ECHO_HALF_LIFE_%s" % _env_suffix)
    if _env_val is not None:
        try:
            _parsed = float(_env_val)
            if _parsed > 0:
                _LAYER_HALF_LIFE_DAYS[_lyr] = max(_parsed, 0.001)
        except ValueError:
            pass


_WEIGHT_ENV_MAP = {
    "relevance": "ECHO_WEIGHT_RELEVANCE",
    "importance": "ECHO_WEIGHT_IMPORTANCE",
    "recency": "ECHO_WEIGHT_RECENCY",
    "proximity": "ECHO_WEIGHT_PROXIMITY",
    "frequency": "ECHO_WEIGHT_FREQUENCY",
}


def _parse_weight_from_env(key: str, env_name: str) -> float:
    """Parse a single weight from an env var, falling back to default."""
    raw = os.environ.get(env_name)
    if raw is None:
        return _DEFAULT_WEIGHTS[key]
    try:
        val = float(raw)
        if val < 0.0:
            raise ValueError("negative weight")
        return val
    except ValueError:
        print("Warning: invalid %s=%r, using default %.2f"
              % (env_name, raw, _DEFAULT_WEIGHTS[key]), file=sys.stderr)
        return _DEFAULT_WEIGHTS[key]


def _normalize_weights(weights: Dict[str, float]) -> Dict[str, float]:
    """EDGE-002: Auto-normalize weights to sum to 1.0."""
    total = sum(weights.values())
    if total <= 0.0:
        print("Warning: scoring weights sum to 0, falling back to defaults",
              file=sys.stderr)
        return dict(_DEFAULT_WEIGHTS)
    if abs(total - 1.0) > 1e-6:
        print("Warning: scoring weights sum to %.4f (not 1.0), "
              "auto-normalizing" % total, file=sys.stderr)
        return {k: v / total for k, v in weights.items()}
    return weights


def _load_scoring_weights() -> Dict[str, float]:
    """Load composite scoring weights from environment variables."""
    weights = {k: _parse_weight_from_env(k, env)
               for k, env in _WEIGHT_ENV_MAP.items()}
    return _normalize_weights(weights)


def _score_bm25_relevance(scores: List[float]) -> List[float]:
    """Normalize BM25 scores to 0.0-1.0 range via min-max scaling.

    BM25 sign convention: FTS5 bm25() returns negative values where more
    negative = more relevant. We invert: 1.0 = most relevant, 0.0 = least.

    Args:
        scores: Raw BM25 scores (negative floats) from FTS5.

    Returns:
        List of normalized scores in [0.0, 1.0].
    """
    if not scores:
        return []
    # EDGE-006: Single result gets score 1.0
    if len(scores) == 1:
        return [1.0]
    bm25_min = min(scores)  # Most relevant (most negative)
    bm25_max = max(scores)  # Least relevant (least negative)
    spread = bm25_max - bm25_min
    # EDGE-005: All scores identical → all equally relevant
    if abs(spread) < 1e-9:
        return [1.0] * len(scores)
    return [(bm25_max - s) / spread for s in scores]


def _score_importance(layer: str, is_doc_pack: bool = False) -> float:
    """Score entry importance based on its echo layer.

    Args:
        layer: Echo layer name (Etched, Inscribed, Traced, Notes, Observations).
        is_doc_pack: Whether the entry originates from a doc pack. Doc-pack
            entries receive a 0.7x discount to prevent them from outranking
            user-authored etched echoes (A3 enrichment).

    Returns:
        Importance score in [0.0, 1.0]. Unknown layers get 0.3 (same as Traced).
    """
    score = _LAYER_IMPORTANCE.get(layer.lower() if layer else "", 0.3)
    if is_doc_pack:
        score *= _DOC_PACK_IMPORTANCE_DISCOUNT
    return score


def _score_recency(
    entry: Dict[str, Any],
    access_counts: Optional[Dict[str, int]] = None,
) -> float:
    """Score entry recency using layer-aware exponential decay.

    When ECHO_DECAY_ENABLED=true (default), uses per-layer half-lives:
    Etched=inf (always 1.0), Notes=180d, Inscribed=90d, Observations=45d,
    Traced=30d. Access counts provide a freshness boost (each access
    subtracts virtual days from age).

    When ECHO_DECAY_ENABLED=false, falls back to fixed 30-day half-life.

    Args:
        entry: Entry dict with 'date', 'layer', and optionally 'id' keys.
        access_counts: Optional dict mapping entry_id -> access count.

    Returns:
        Recency score in [_RECENCY_FLOOR, 1.0]. Returns _RECENCY_FLOOR for
        missing/malformed dates (EDGE-003).
    """
    date_str = entry.get("date", "") if isinstance(entry, dict) else ""
    if not date_str:
        return _RECENCY_FLOOR if _DECAY_ENABLED else 0.0
    try:
        entry_date = datetime.strptime(date_str[:10], "%Y-%m-%d").replace(
            tzinfo=timezone.utc
        )
        now = datetime.now(timezone.utc)
        age_days = max((now - entry_date).days, 0)

        if not _DECAY_ENABLED:
            # Legacy mode: fixed 30-day half-life, no floor
            return math.pow(2.0, -age_days / _RECENCY_HALF_LIFE_DAYS)

        # Access freshness boost: each access subtracts virtual days
        if access_counts:
            entry_id = entry.get("id", "")
            count = access_counts.get(entry_id, 0)
            if count > 0:
                age_days = max(age_days - count * _ACCESS_BOOST_DAYS, 0)

        # Layer-aware half-life
        layer = (entry.get("layer", "") or "").lower()
        half_life = _LAYER_HALF_LIFE_DAYS.get(layer, _RECENCY_HALF_LIFE_DAYS)

        # Infinite half-life → always fresh
        if half_life == float("inf"):
            return 1.0

        score = math.pow(2.0, -age_days / half_life)
        return max(score, _RECENCY_FLOOR)
    except (ValueError, TypeError):
        # EDGE-003: Malformed date → floor score
        return _RECENCY_FLOOR if _DECAY_ENABLED else 0.0


# Regex for extracting file paths from echo content (C5 concern).
# Matches backtick-fenced tokens that look like file paths (contain / and end
# with a common extension). Limited to 10 evidence paths per entry.
_EVIDENCE_PATH_RE = re.compile(r'`([^`]+\.[a-z]{1,6})`')


def _extract_evidence_paths(entry: Dict[str, Any]) -> List[str]:
    """Extract file paths from entry content/source/file_path (C5, max 10, string-only)."""
    paths = []  # type: List[str]

    # VOID-003: Include entry's own file_path for proximity scoring
    file_path = entry.get("file_path", "") or ""
    if file_path and ("/" in file_path or os.sep in file_path):
        paths.append(os.path.normpath(file_path))

    # Extract from content (content_preview in search results)
    content = entry.get("content_preview", "") or entry.get("full_content", "") or ""
    for match in _EVIDENCE_PATH_RE.finditer(content):
        candidate = match.group(1)
        # Filter to paths that contain a directory separator
        if "/" in candidate or os.sep in candidate:
            paths.append(os.path.normpath(candidate))

    # Extract from source field
    source = entry.get("source", "") or ""
    if source and ("/" in source or os.sep in source):
        # Source might be like "rune:appraise src/auth.py" — extract path-like tokens
        for token in source.split():
            if "/" in token and ":" not in token:
                paths.append(os.path.normpath(token))

    # Deduplicate while preserving order, cap at 10
    seen = set()  # type: set
    unique = []  # type: List[str]
    for p in paths:
        if p not in seen:
            seen.add(p)
            unique.append(p)
            if len(unique) >= 10:
                break

    return unique


def compute_file_proximity(evidence_path: str, context_path: str) -> float:
    """Compute proximity: 1.0=exact, 0.8=same dir, 0.2-0.6=shared prefix, 0.0=none.

    String comparison ONLY (no filesystem access on untrusted MCP input).
    """
    # EDGE-012: Normalize both paths (no realpath — no filesystem access)
    ev = os.path.normpath(evidence_path)
    ctx = os.path.normpath(context_path)

    # Exact match
    if ev == ctx:
        return 1.0

    # Same directory
    ev_dir = os.path.dirname(ev)
    ctx_dir = os.path.dirname(ctx)
    if ev_dir and ev_dir == ctx_dir:
        return 0.8

    # Shared prefix — score proportional to common path depth
    ev_parts = [p for p in ev.split(os.sep) if p]
    ctx_parts = [p for p in ctx.split(os.sep) if p]
    common = 0
    for a, b in zip(ev_parts, ctx_parts):
        if a == b:
            common += 1
        else:
            break

    if common == 0:
        return 0.0

    max_depth = max(len(ev_parts), len(ctx_parts))
    if max_depth == 0:
        return 0.0

    # Scale from 0.2 to 0.6 based on common prefix ratio
    ratio = common / max_depth
    return 0.2 + 0.4 * ratio


def _score_proximity(entry: Dict[str, Any], context_files: Optional[List[str]] = None) -> float:
    """Score file proximity between echo evidence files and context files.

    Extracts file paths referenced in the echo entry content, then computes
    the best proximity score against the user's current context files.

    Args:
        entry: Echo entry dict with content_preview, source, etc.
        context_files: List of currently open/edited file paths (untrusted
            MCP input — string comparison only, no filesystem access).

    Returns:
        Proximity score in [0.0, 1.0]. Returns 0.0 if no context files
        or no evidence paths found (EDGE-011).
    """
    # EDGE-011: Unified guard for None, [], and omitted context_files
    if not context_files:
        return 0.0

    evidence_paths = _extract_evidence_paths(entry)
    if not evidence_paths:
        return 0.0

    # Best proximity across all evidence/context path pairs
    best = 0.0
    for ev in evidence_paths:
        for ctx in context_files:
            ctx_norm = os.path.normpath(ctx)
            score = compute_file_proximity(ev, ctx_norm)
            if score > best:
                best = score
            if best >= 1.0:
                return 1.0  # Can't do better than exact match

    return best


def _get_access_counts(conn: sqlite3.Connection, entry_ids: List[str]) -> Dict[str, int]:
    """Fetch access counts for a batch of entry IDs from echo_access_log.

    Uses a single query with IN clause for efficiency. Only counts accesses
    for entries that still exist in echo_entries (EDGE-007: orphan safety).

    Args:
        conn: Database connection with echo_access_log table.
        entry_ids: List of echo entry IDs to look up.

    Returns:
        Dict mapping entry_id to access count. Missing IDs have count 0.
    """
    if not entry_ids:
        return {}
    # Cap to prevent oversized IN clause
    capped_ids = entry_ids[:200]
    cursor = conn.execute(
        """SELECT entry_id, COUNT(*) AS cnt
           FROM echo_access_log
           WHERE entry_id IN (%s)
           GROUP BY entry_id""" % _in_clause(len(capped_ids)),
        capped_ids,
    )
    return {row["entry_id"]: row["cnt"] for row in cursor.fetchall()}


def _score_frequency(
    entry_id: str,
    conn: Optional[sqlite3.Connection] = None,
    access_counts: Optional[Dict[str, int]] = None,
    max_log_count: float = 0.0,
) -> float:
    """Score access frequency from echo_access_log.

    Uses log(1+count) scaling to prevent high-access entries from
    dominating — diminishing returns after the first few accesses.
    Normalized to [0.0, 1.0] by dividing by the max log-count in
    the current result set.

    Args:
        entry_id: Echo entry ID.
        conn: Database connection (unused when access_counts provided).
        access_counts: Pre-fetched dict of entry_id -> count (batch mode).
        max_log_count: Maximum log(1+count) across the result set for
            normalization. If 0.0, returns 0.0 (EDGE-004).

    Returns:
        Frequency score in [0.0, 1.0].
    """
    if access_counts is None:
        # EDGE-004: No access data → return 0.0
        return 0.0
    count = access_counts.get(entry_id, 0)
    if count == 0:
        return 0.0
    # EDGE-004: max_log_count=0 → return 0.0 (division by zero guard)
    if max_log_count <= 0.0:
        return 0.0
    return math.log(1.0 + count) / max_log_count


def _cap_access_log(conn: sqlite3.Connection) -> None:
    """EDGE-010: Prune access log if over 100k rows (keep newest 90k)."""
    row_count = conn.execute(
        "SELECT COUNT(*) FROM echo_access_log").fetchone()[0]
    if row_count > 100000:
        conn.execute("""DELETE FROM echo_access_log
            WHERE id NOT IN (
                SELECT id FROM echo_access_log
                ORDER BY accessed_at DESC LIMIT 90000)""")
        conn.commit()


def _record_access(
    conn: sqlite3.Connection,
    results: List[Dict[str, Any]],
    query: str,
) -> None:
    """Record access events synchronously (C2 concern, EDGE-010 cap)."""
    if not results:
        return
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    try:
        for entry in results:
            entry_id = entry.get("id", "")
            if entry_id:
                conn.execute(
                    "INSERT INTO echo_access_log "
                    "(entry_id, accessed_at, query) VALUES (?, ?, ?)",
                    (entry_id, now, query[:500]))
                # BACK-014: Auto-unarchive entries when accessed
                conn.execute(
                    "UPDATE echo_entries SET archived = 0 "
                    "WHERE id = ? AND archived = 1",
                    (entry_id,))
        conn.commit()
        _cap_access_log(conn)
    except sqlite3.OperationalError as exc:
        logger.debug("_record_access failed: %s", exc)


def _prepare_frequency_data(
    conn: Optional[sqlite3.Connection],
    results: List[Dict[str, Any]],
) -> Tuple[Optional[Dict[str, int]], float]:
    """Batch-fetch access counts for frequency scoring.

    Returns (access_counts, max_log_count) tuple.
    """
    if conn is None:
        return None, 0.0
    entry_ids = [r.get("id", "") for r in results if r.get("id")]
    access_counts = _get_access_counts(conn, entry_ids)
    max_log_count = 0.0
    if access_counts:
        max_log_count = max(
            math.log(1.0 + c) for c in access_counts.values())
    return access_counts, max_log_count


def _is_doc_pack_entry(entry: Dict[str, Any]) -> bool:
    """Check if an entry originates from a doc pack."""
    source = entry.get("source", "")
    return isinstance(source, str) and source.startswith("doc-pack:")


# A3 enrichment: doc-pack importance discount factor to prevent doc packs
# from outranking user-authored etched echoes.
_DOC_PACK_IMPORTANCE_DISCOUNT = 0.7


def _compute_entry_factors(
    entry: Dict[str, Any], bm25_norm: float,
    context_files: Optional[List[str]],
    conn: Optional[sqlite3.Connection],
    access_counts: Optional[Dict[str, int]],
    max_log_count: float,
) -> Dict[str, float]:
    """Compute all 5 scoring factors for a single entry."""
    importance = _score_importance(
        entry.get("layer", ""), is_doc_pack=_is_doc_pack_entry(entry))
    return {
        "relevance": bm25_norm,
        "importance": importance,
        "recency": _score_recency(entry, access_counts),
        "proximity": _score_proximity(entry, context_files),
        "frequency": _score_frequency(
            entry.get("id", ""), conn=conn,
            access_counts=access_counts, max_log_count=max_log_count),
    }


def _enrich_entry(
    entry: Dict[str, Any], factors: Dict[str, float],
    weights: Dict[str, float],
) -> Tuple[float, Dict[str, Any]]:
    """Compute composite score and enrich entry with score metadata."""
    composite = sum(weights.get(k, 0.0) * v for k, v in factors.items())
    enriched = dict(entry)
    enriched["composite_score"] = round(composite, 4)
    enriched["score_factors"] = {k: round(v, 4) for k, v in factors.items()}
    return composite, enriched


def compute_composite_score(
    results: List[Dict[str, Any]],
    weights: Dict[str, float],
    conn: Optional[sqlite3.Connection] = None,
    context_files: Optional[List[str]] = None,
) -> List[Dict[str, Any]]:
    """Re-rank search results using 5-factor composite scoring.

    Args:
        results: Search result dicts with 'score', 'layer', 'id', etc.
        weights: Factor weights summing to 1.0.
        conn: Optional DB connection for frequency lookups.
        context_files: Optional file paths for proximity scoring.

    Returns:
        Re-sorted results with 'composite_score' and 'score_factors'.
    """
    if not results:
        return []

    raw_bm25 = [r.get("score", 0.0) for r in results]
    norm_bm25 = _score_bm25_relevance(raw_bm25)
    access_counts, max_log_count = _prepare_frequency_data(conn, results)

    scored = []  # type: List[Tuple[float, Dict[str, Any]]]
    for i, entry in enumerate(results):
        factors = _compute_entry_factors(
            entry, norm_bm25[i], context_files,
            conn, access_counts, max_log_count)
        scored.append(_enrich_entry(entry, factors, weights))

    scored.sort(key=lambda x: x[0], reverse=True)
    return [entry for _, entry in scored]


# Load weights once at module level (evaluated at import time).
# This avoids re-parsing env vars on every search call.
_SCORING_WEIGHTS = _load_scoring_weights()


# ---------------------------------------------------------------------------
# Database helpers
# ---------------------------------------------------------------------------

def get_db(db_path):
    """Open a SQLite connection with WAL mode and Row factory.

    Args:
        db_path: Absolute path to the SQLite database file.

    Returns:
        Connection with row_factory=sqlite3.Row, journal_mode=WAL,
        and busy_timeout=5000ms.
    """
    # type: (str) -> sqlite3.Connection
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


def _tokenize_for_grouping(text: str) -> set[str]:
    # NOTE: set[str] and other PEP 585 lowercase generics (list[str], dict[K,V])
    # require `from __future__ import annotations` (present at top of file) for
    # Python < 3.9 compatibility.  Without that import this annotation would raise
    # TypeError at import time on Python 3.7/3.8.
    """Extract lowercased, stopword-filtered tokens for Jaccard similarity."""
    tokens = re.findall(r"[a-zA-Z0-9_]+", text.lower())
    return {t for t in tokens if t not in STOPWORDS and len(t) >= 2}


def _evidence_basenames(entry: Dict[str, Any]) -> set[str]:
    """Extract basenames of evidence file paths from an entry."""
    basenames = set()  # type: set[str]
    content = entry.get("content", "") or entry.get("content_preview", "") or ""
    for match in _EVIDENCE_PATH_RE.finditer(content):
        candidate = match.group(1)
        if "/" in candidate or os.sep in candidate:
            basenames.add(os.path.basename(candidate).lower())
    source = entry.get("source", "") or ""
    for token in source.split():
        if "/" in token and ":" not in token:
            basenames.add(os.path.basename(token).lower())
    file_path = entry.get("file_path", "") or ""
    if file_path:
        basenames.add(os.path.basename(file_path).lower())
    return basenames


def compute_entry_similarity(entry_a: Dict[str, Any], entry_b: Dict[str, Any]) -> float:
    """Compute Jaccard similarity between two echo entries (EDGE-007)."""
    features_a = _evidence_basenames(entry_a) | _tokenize_for_grouping(
        (entry_a.get("content", "") or "") + " " + (entry_a.get("tags", "") or ""))
    features_b = _evidence_basenames(entry_b) | _tokenize_for_grouping(
        (entry_b.get("content", "") or "") + " " + (entry_b.get("tags", "") or ""))
    if not features_a and not features_b:
        return 0.0
    union = features_a | features_b
    return len(features_a & features_b) / len(union) if union else 0.0


def _merge_pair_into_groups(groups, id_a, id_b, sim):
    """Merge a similar pair into the groups list (union-find logic)."""
    group_a = group_b = None
    for g in groups:
        if id_a in g[1]:
            group_a = g
        if id_b in g[1]:
            group_b = g
    if group_a is None and group_b is None:
        groups.append((uuid.uuid4().hex[:16], {id_a, id_b}, {id_a: sim, id_b: sim}))
    elif group_a is not None and group_b is None:
        group_a[1].add(id_b)
        group_a[2][id_b] = max(group_a[2].get(id_b, 0.0), sim)
    elif group_a is None and group_b is not None:
        group_b[1].add(id_a)
        group_b[2][id_a] = max(group_b[2].get(id_a, 0.0), sim)
    elif group_a is not None and group_b is not None and group_a is not group_b:
        group_a[1].update(group_b[1])
        for eid, s in group_b[2].items():
            group_a[2][eid] = max(group_a[2].get(eid, 0.0), s)
        groups.remove(group_b)
    elif group_a is group_b and group_a is not None:
        group_a[2][id_a] = max(group_a[2].get(id_a, 0.0), sim)
        group_a[2][id_b] = max(group_a[2].get(id_b, 0.0), sim)


def _build_pairwise_groups(entry_map, entry_ids, threshold):
    """Build groups via token-indexed similarity comparison.

    Uses an inverted index to avoid O(n²) full pairwise scan — only pairs
    sharing at least one feature token are compared.
    """
    if len(entry_ids) > 500:
        logger.warning("_build_pairwise_groups: skipping — %d entries exceeds 500 cap", len(entry_ids))
        return []

    # Phase 1: Build feature sets and inverted index (token → entry IDs)
    feature_cache = {}  # type: dict[str, set[str]]
    inverted_index = {}  # type: dict[str, set[str]]
    for eid in entry_ids:
        entry = entry_map[eid]
        features = _evidence_basenames(entry) | _tokenize_for_grouping(
            (entry.get("content", "") or "") + " " + (entry.get("tags", "") or ""))
        feature_cache[eid] = features
        for token in features:
            if token not in inverted_index:
                inverted_index[token] = set()
            inverted_index[token].add(eid)

    # Phase 2: Collect candidate pairs (share at least one token)
    candidate_pairs = set()  # type: set[tuple[str, str]]
    for token_entries in inverted_index.values():
        entries_list = sorted(token_entries)  # deterministic order
        for i in range(len(entries_list)):
            for j in range(i + 1, len(entries_list)):
                candidate_pairs.add((entries_list[i], entries_list[j]))

    logger.debug("_build_pairwise_groups: %d candidates from %d entries (full pairwise would be %d)",
                 len(candidate_pairs), len(entry_ids), len(entry_ids) * (len(entry_ids) - 1) // 2)

    # Phase 3: Compute similarity only for candidate pairs
    groups = []  # type: list[tuple[str, set[str], dict[str, float]]]
    for id_a, id_b in candidate_pairs:
        features_a = feature_cache[id_a]
        features_b = feature_cache[id_b]
        if not features_a and not features_b:
            continue
        union = features_a | features_b
        sim = len(features_a & features_b) / len(union) if union else 0.0
        if sim >= threshold:
            _merge_pair_into_groups(groups, id_a, id_b, sim)
    return [g for g in groups if len(g[1]) >= 2]


def _chunk_groups(groups, max_group_size):
    """Split oversized groups into chunks of max_group_size."""
    final = []  # type: list[tuple[str, set[str], dict[str, float]]]
    for gid, members, sims in groups:
        if len(members) <= max_group_size:
            final.append((gid, members, sims))
        else:
            sorted_m = sorted(members, key=lambda eid: sims.get(eid, 0.0), reverse=True)
            for cs in range(0, len(sorted_m), max_group_size):
                chunk = set(sorted_m[cs:cs + max_group_size])
                if len(chunk) >= 2:
                    final.append(
                        (gid if cs == 0 else uuid.uuid4().hex[:16], chunk,
                         {eid: sims.get(eid, 0.0) for eid in chunk}))
    return final


def _write_groups(conn, final_groups):
    """Atomically write group memberships to semantic_groups table."""
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    count = 0
    conn.execute("SAVEPOINT write_groups")
    try:
        for gid, members, sims in final_groups:
            for eid in members:
                conn.execute(
                    "INSERT OR REPLACE INTO semantic_groups "
                    "(group_id, entry_id, similarity, created_at) "
                    "VALUES (?, ?, ?, ?)",
                    (gid, eid, sims.get(eid, 0.0), now))
                count += 1
        conn.execute("RELEASE SAVEPOINT write_groups")
    except sqlite3.Error:
        conn.execute("ROLLBACK TO SAVEPOINT write_groups")
        raise
    return count


def assign_semantic_groups(
    conn: sqlite3.Connection, entries: list[Dict[str, Any]],
    threshold: float = 0.3, max_group_size: int = 20,
) -> int:
    """Assign entries to semantic groups based on Jaccard similarity.

    Args:
        conn: SQLite database connection with V2 schema.
        entries: List of entry dicts with 'id', 'content', 'tags'.
        threshold: Minimum Jaccard similarity for grouping.
        max_group_size: Max entries per group chunk.

    Returns:
        Total group membership rows inserted or replaced.
    """
    if len(entries) < 2:
        return 0
    entry_map = {e["id"]: e for e in entries}
    entry_ids = list(entry_map.keys())
    groups = _build_pairwise_groups(entry_map, entry_ids, threshold)
    final_groups = _chunk_groups(groups, max_group_size)
    return _write_groups(conn, final_groups)


def upsert_semantic_group(
    conn: sqlite3.Connection, group_id: str,
    entry_ids: list[str], similarities: list[float] | None = None,
) -> int:
    """Insert or replace semantic group memberships (INSERT OR REPLACE).

    Validates that all entry_ids exist in echo_entries before inserting.
    Returns count of memberships created. Raises ValueError for missing entries.
    """
    if not entry_ids:
        return 0
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    if similarities is None:
        similarities = [0.0] * len(entry_ids)
    elif len(similarities) != len(entry_ids):
        raise ValueError(
            f"entry_ids ({len(entry_ids)}) and similarities ({len(similarities)}) "
            f"must have the same length"
        )
    # FK validation: filter to existing entry_ids (partial success — skip missing)
    existing = frozenset(
        r[0] for r in conn.execute(
            "SELECT id FROM echo_entries WHERE id IN (%s)"
            % _in_clause(len(entry_ids)),
            entry_ids,
        ).fetchall()
    )
    skipped = [eid for eid in entry_ids if eid not in existing]
    # Filter entry_ids and similarities to only existing entries
    filtered = [
        (eid, sim) for eid, sim in zip(entry_ids, similarities)
        if eid in existing
    ]
    if not filtered:
        return 0
    count = 0
    conn.execute("BEGIN")
    try:
        for eid, sim in filtered:
            conn.execute(
                "INSERT OR REPLACE INTO semantic_groups (group_id, entry_id, similarity, created_at) VALUES (?, ?, ?, ?)",
                (group_id, eid, sim, now))
            count += 1
        conn.commit()
    except sqlite3.Error:
        conn.rollback()
        raise
    if skipped:
        logger.warning("upsert_semantic_group: skipped %d missing entry_ids: %s",
                        len(skipped), skipped)
    return count


def _fetch_group_ids(
    conn: sqlite3.Connection, existing_ids: set,
) -> List[str]:
    """Fetch distinct group IDs for a set of entry IDs.

    Returns empty list on pre-V2 schema (table missing).
    """
    id_list = list(existing_ids)
    try:
        rows = conn.execute(
            "SELECT DISTINCT group_id FROM semantic_groups "
            "WHERE entry_id IN (%s)" % _in_clause(len(id_list)),
            id_list,
        ).fetchall()
    except sqlite3.OperationalError:
        return []
    return [r[0] for r in rows]


def _fetch_expanded_rows(
    conn: sqlite3.Connection, group_ids: List[str],
    existing_ids: set,
) -> list:
    """Fetch group member rows not already in results."""
    id_list = list(existing_ids)
    try:
        return conn.execute(
            """SELECT sg.group_id, e.id, e.source, e.layer, e.role,
                      e.date, substr(e.content, 1, 200) AS content_preview,
                      e.line_number, e.tags, e.category
               FROM semantic_groups sg
               JOIN echo_entries e ON e.id = sg.entry_id
               WHERE sg.group_id IN (%s)
                 AND sg.entry_id NOT IN (%s)
                 AND e.archived = 0"""
            % (_in_clause(len(group_ids)), _in_clause(len(id_list))),
            group_ids + id_list,
        ).fetchall()
    except sqlite3.OperationalError:
        return []


def _rows_to_expanded_entries(rows: list) -> list:
    """Convert DB rows to expanded entry dicts."""
    entries = []  # type: list[Dict[str, Any]]
    for row in rows:
        entries.append({
            "id": row["id"], "source": row["source"],
            "layer": row["layer"], "role": row["role"],
            "date": row["date"], "content_preview": row["content_preview"],
            "line_number": row["line_number"], "tags": row["tags"],
            "score": 0.0, "expansion_source": "group_expansion",
        })
    return entries


def _dedup_expanded(
    entries: list, existing_ids: set, cap: int,
) -> list:
    """Deduplicate expanded entries and cap total count."""
    seen = set()  # type: set[str]
    unique = []  # type: list[Dict[str, Any]]
    for entry in entries:
        eid = entry["id"]
        if eid not in seen and eid not in existing_ids:
            seen.add(eid)
            unique.append(entry)
    return unique[:min(cap, 50)]


def _merge_scored_results(
    original: list, expanded: list,
) -> list:
    """Merge original + expanded, dedup by highest composite_score."""
    combined = {}  # type: dict[str, Dict[str, Any]]
    for entry in original:
        eid = entry.get("id", "")
        if eid:
            combined[eid] = entry
    for entry in expanded:
        eid = entry.get("id", "")
        if eid and (eid not in combined or
                    entry.get("composite_score", 0.0) >
                    combined[eid].get("composite_score", 0.0)):
            combined[eid] = entry
    return sorted(
        combined.values(),
        key=lambda x: x.get("composite_score", 0.0),
        reverse=True,
    )


def _apply_expansion_discount(
    scored_expanded: List[Dict[str, Any]], discount: float,
) -> None:
    """Apply discount multiplier and mark expansion source on entries."""
    for entry in scored_expanded:
        entry["composite_score"] = round(
            entry.get("composite_score", 0.0) * discount, 4)
        entry["expansion_source"] = "group_expansion"


def expand_semantic_groups(
    conn: sqlite3.Connection,
    scored_results: list[Dict[str, Any]],
    weights: Dict[str, float],
    context_files: Optional[List[str]] = None,
    discount: float = 0.7,
    max_expansion: int = 5,
) -> list[Dict[str, Any]]:
    """Expand results with semantic group members (EDGE-010)."""
    if not scored_results:
        return scored_results
    existing_ids = {r.get("id", "") for r in scored_results if r.get("id")}
    if not existing_ids:
        return scored_results

    group_ids = _fetch_group_ids(conn, existing_ids)
    if not group_ids:
        return scored_results

    expanded_rows = _fetch_expanded_rows(conn, group_ids, existing_ids)
    if not expanded_rows:
        return scored_results

    entries = _rows_to_expanded_entries(expanded_rows)
    cap = max_expansion * len(group_ids)
    unique = _dedup_expanded(entries, existing_ids, cap)
    if not unique:
        return scored_results

    scored_expanded = compute_composite_score(
        unique, weights, conn=conn, context_files=context_files)
    _apply_expansion_discount(scored_expanded, discount)
    return _merge_scored_results(scored_results, scored_expanded)


def _insert_entries(conn: sqlite3.Connection, entries: list) -> None:
    """Clear existing entries and insert new ones into echo_entries."""
    conn.execute("DELETE FROM echo_entries")
    conn.execute(
        "INSERT INTO echo_entries_fts(echo_entries_fts) VALUES('delete-all')")
    for entry in entries:
        conn.execute(
            """INSERT OR REPLACE INTO echo_entries
               (id, role, layer, date, source, content, tags,
                line_number, file_path, category, domain)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (entry["id"], entry["role"], entry["layer"],
             entry.get("date", ""), entry.get("source", ""),
             entry["content"], entry.get("tags", ""),
             entry.get("line_number", 0), entry["file_path"],
             entry.get("category", "general"),
             entry.get("domain", "general")),
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


def _backup_semantic_groups(conn: sqlite3.Connection) -> List[Tuple[str, str, float, str]]:
    """Back up semantic group memberships before DELETE+INSERT cycle."""
    try:
        rows = conn.execute(
            "SELECT group_id, entry_id, similarity, created_at "
            "FROM semantic_groups"
        ).fetchall()
        return [(r[0], r[1], r[2], r[3]) for r in rows]
    except sqlite3.OperationalError:
        return []  # Pre-V2 schema


def _restore_semantic_groups(
    conn: sqlite3.Connection,
    backup: List[Tuple[str, str, float, str]],
) -> int:
    """Restore semantic group memberships, skipping entries that no longer exist."""
    if not backup:
        return 0
    existing_ids = frozenset(
        r[0] for r in conn.execute("SELECT id FROM echo_entries").fetchall()
    )
    restored = 0
    for group_id, entry_id, similarity, created_at in backup:
        if entry_id not in existing_ids:
            continue
        try:
            conn.execute(
                "INSERT OR IGNORE INTO semantic_groups "
                "(group_id, entry_id, similarity, created_at) "
                "VALUES (?, ?, ?, ?)",
                (group_id, entry_id, similarity, created_at),
            )
            restored += 1
        except sqlite3.Error:
            continue
    # Cleanup degenerate groups (fewer than 2 members)
    try:
        conn.execute("""
            DELETE FROM semantic_groups WHERE group_id IN (
                SELECT group_id FROM semantic_groups
                GROUP BY group_id HAVING COUNT(*) < 2
            )
        """)
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
        group_backup = _backup_semantic_groups(conn)
        _insert_entries(conn, entries)
        _restore_semantic_groups(conn, group_backup)
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
# Talisman config with mtime caching (Task 7)
# ---------------------------------------------------------------------------

_talisman_cache = {"mtime": 0.0, "path": "", "config": {}}  # type: Dict[str, Any]
_RUNE_TRACE = os.environ.get("RUNE_TRACE", "") == "1"


def _trace(stage: str, start: float) -> None:
    """Log pipeline stage timing to stderr when RUNE_TRACE=1 (EDGE-029)."""
    if _RUNE_TRACE:
        elapsed_ms = (time.time() - start) * 1000
        print("[echo-search] %s: %.1fms" % (stage, elapsed_ms), file=sys.stderr)


def _talisman_search_paths() -> List[str]:
    """Build ordered list of talisman.yml candidate paths."""
    paths = []
    if ECHO_DIR:
        claude_dir = os.path.dirname(ECHO_DIR.rstrip(os.sep))
        paths.append(os.path.join(claude_dir, "talisman.yml"))
    config_dir = os.environ.get(
        "CLAUDE_CONFIG_DIR", os.path.expanduser("~/.claude"))
    paths.append(os.path.join(config_dir, "talisman.yml"))
    return paths


def _try_load_talisman_file(
    talisman_path: str, mtime: float,
) -> Optional[Dict[str, Any]]:
    """Try reading and caching a single talisman.yml file."""
    if (mtime == _talisman_cache["mtime"]
            and talisman_path == _talisman_cache["path"]
            and _talisman_cache["config"]):
        return _talisman_cache["config"]
    try:
        import yaml
    except ImportError:
        return None
    try:
        # SEC-002: Verify realpath stays within the expected parent directory
        # to prevent symlink-based path traversal attacks.
        expected_root = os.path.realpath(os.path.dirname(talisman_path))
        real_talisman = os.path.realpath(talisman_path)
        try:
            if os.path.commonpath([expected_root, real_talisman]) != expected_root:
                logger.debug(
                    "talisman path escapes expected root (symlink?): %s",
                    talisman_path)
                return None
        except ValueError:
            return None
        with open(talisman_path, "r") as f:
            config = yaml.safe_load(f)
        if isinstance(config, dict):
            _talisman_cache["mtime"] = mtime
            _talisman_cache["path"] = talisman_path
            _talisman_cache["config"] = config
            return config
    except (OSError, ValueError) as exc:
        logger.debug("talisman load error for %s: %s", talisman_path, exc)
    return None


def _load_talisman() -> Dict[str, Any]:
    """Load talisman.yml with mtime caching. Returns {} on failure."""
    for path in _talisman_search_paths():
        try:
            mtime = os.path.getmtime(path)
        except OSError:
            continue
        result = _try_load_talisman_file(path, mtime)
        if result is not None:
            return result
    return {}


def _get_echoes_config(talisman: Dict[str, Any], key: str) -> Dict[str, Any]:
    """Extract a nested echoes config section from talisman.

    Args:
        talisman: Full talisman config dict.
        key: Config key under 'echoes' (e.g., 'decomposition', 'reranking').

    Returns:
        Config dict for the section, or empty dict if not found.
    """
    echoes = talisman.get("echoes", {})
    if not isinstance(echoes, dict):
        return {}
    section = echoes.get(key, {})
    return section if isinstance(section, dict) else {}


# ---------------------------------------------------------------------------
# Multi-pass retrieval pipeline (Task 7)
# ---------------------------------------------------------------------------

async def _pipeline_decompose(
    query: str, decomp_config: Dict[str, Any],
) -> List[str]:
    """Stage 1: Query decomposition (async subprocess, 3s timeout)."""
    facets = [query]
    if not decomp_config.get("enabled", False):
        return facets
    t0 = time.time()
    try:
        from decomposer import decompose_query
        facets = await decompose_query(query)
        if not facets:
            facets = [query]
    except (ImportError, OSError) as e:
        if _RUNE_TRACE:
            print("[echo-search] decomposition error: %s" % e, file=sys.stderr)
        facets = [query]
    _trace("decomposition", t0)
    return facets


def _pipeline_bm25_search(
    conn: sqlite3.Connection, facets: List[str],
    overfetch_limit: int, layer: Optional[str], role: Optional[str],
    category: Optional[str] = None, domain: Optional[str] = None,
) -> List[Dict[str, Any]]:
    """Stage 2-3: Per-facet BM25 search and merge."""
    t0 = time.time()
    all_facet_results = []  # type: list[list[Dict[str, Any]]]
    for facet in facets:
        kwargs = {}  # type: Dict[str, Any]
        if domain is not None:
            kwargs["domain"] = domain
        all_facet_results.append(
            search_entries(conn, facet, overfetch_limit, layer, role,
                           category, **kwargs))
    _trace("bm25_search (%d facets)" % len(facets), t0)

    t0 = time.time()
    if len(all_facet_results) == 1:
        candidates = all_facet_results[0]
    else:
        try:
            from decomposer import merge_results_by_best_score
            candidates = merge_results_by_best_score(all_facet_results)
        except ImportError:
            candidates = all_facet_results[0] if all_facet_results else []
    _trace("merge", t0)
    return candidates


def _populate_related_entries(
    results: List[Dict[str, Any]],
    conn: sqlite3.Connection,
    category_filter: Optional[str] = None,
) -> None:
    """Add related_entries field to each result via semantic group co-membership.

    For each result, finds other entries in the same semantic groups,
    excluding archived entries and optionally filtering by category.
    Modifies results in place.
    """
    if not results:
        return
    entry_ids = [r.get("id", "") for r in results if r.get("id")]
    if not entry_ids:
        return
    result_id_set = frozenset(entry_ids)
    # Batch: get all group memberships for result entry IDs
    try:
        group_rows = conn.execute(
            "SELECT entry_id, group_id FROM semantic_groups "
            "WHERE entry_id IN (%s)" % _in_clause(len(entry_ids)),
            entry_ids,
        ).fetchall()
    except sqlite3.OperationalError:
        return  # Pre-V2 schema
    if not group_rows:
        for r in results:
            r["related_entries"] = []
        return
    # Map entry_id -> set of group_ids
    entry_groups = {}  # type: Dict[str, set]
    all_group_ids = set()  # type: set
    for row in group_rows:
        eid = row[0]
        gid = row[1]
        entry_groups.setdefault(eid, set()).add(gid)
        all_group_ids.add(gid)
    # Fetch all members of those groups (excluding archived)
    gid_list = list(all_group_ids)
    base_sql = """SELECT sg.group_id, e.id, e.tags, e.layer, e.role
                  FROM semantic_groups sg
                  JOIN echo_entries e ON e.id = sg.entry_id
                  WHERE sg.group_id IN (%s) AND e.archived = 0""" % _in_clause(len(gid_list))
    params = list(gid_list)  # type: List[Any]
    if category_filter:
        base_sql += " AND e.category = ?"
        params.append(category_filter)
    try:
        member_rows = conn.execute(base_sql, params).fetchall()
    except sqlite3.OperationalError:
        for r in results:
            r["related_entries"] = []
        return
    # Map group_id -> list of member dicts
    group_members = {}  # type: Dict[str, List[Dict[str, Any]]]
    for row in member_rows:
        gid = row[0]
        member = {
            "id": row[1], "tags": row[2],
            "layer": row[3], "role": row[4],
        }
        group_members.setdefault(gid, []).append(member)
    # Populate related_entries for each result
    for r in results:
        eid = r.get("id", "")
        groups = entry_groups.get(eid, set())
        related = {}  # type: Dict[str, Dict[str, Any]]
        for gid in groups:
            for member in group_members.get(gid, []):
                mid = member["id"]
                if mid != eid and mid not in result_id_set and mid not in related:
                    related[mid] = member
        r["related_entries"] = list(related.values())[:10]


def _pipeline_group_expansion(
    conn: sqlite3.Connection, scored: List[Dict[str, Any]],
    groups_config: Dict[str, Any],
    context_files: Optional[List[str]],
) -> List[Dict[str, Any]]:
    """Stage 5: Group expansion (after composite, before retry)."""
    if not groups_config.get("expansion_enabled", False):
        return scored
    t0 = time.time()
    discount = max(0.0, min(1.0, groups_config.get("discount", 0.7)))
    max_exp = max(1, min(50, groups_config.get("max_expansion", 5)))
    scored = expand_semantic_groups(
        conn, scored, _SCORING_WEIGHTS,
        context_files=context_files,
        discount=discount, max_expansion=max_exp,
    )
    _trace("group_expansion", t0)
    return scored


def _pipeline_retry_injection(
    conn: sqlite3.Connection, query: str,
    scored: List[Dict[str, Any]],
    retry_config: Dict[str, Any],
    context_files: Optional[List[str]],
) -> List[Dict[str, Any]]:
    """Stage 6: Retry injection (after expansion, before reranking)."""
    if not retry_config.get("enabled", False):
        return scored
    t0 = time.time()
    fingerprint = compute_token_fingerprint(query)
    if fingerprint:
        matched_ids = [r.get("id", "") for r in scored if r.get("id")]
        retry_entries = get_retry_entries(conn, fingerprint, matched_ids)
        if retry_entries:
            scored = _merge_retry_entries(
                scored, retry_entries, conn, context_files)
    _trace("retry_injection", t0)
    return scored


def _merge_retry_entries(
    scored: List[Dict[str, Any]], retry_entries: List[Dict[str, Any]],
    conn: sqlite3.Connection, context_files: Optional[List[str]],
) -> List[Dict[str, Any]]:
    """Score retry entries and merge with existing scored results."""
    retry_scored = compute_composite_score(
        retry_entries, _SCORING_WEIGHTS, conn=conn,
        context_files=context_files,
    )
    for entry in retry_scored:
        entry["retry_source"] = True
    combined = {r.get("id", ""): r for r in scored if r.get("id")}
    for entry in retry_scored:
        eid = entry.get("id", "")
        if eid and (eid not in combined or
                    entry.get("composite_score", 0.0) >
                    combined[eid].get("composite_score", 0.0)):
            combined[eid] = entry
    return sorted(
        combined.values(),
        key=lambda x: x.get("composite_score", 0.0), reverse=True,
    )


async def _pipeline_rerank(
    query: str, scored: List[Dict[str, Any]],
    rerank_config: Dict[str, Any],
) -> List[Dict[str, Any]]:
    """Stage 7: Haiku reranking (async subprocess, 4s timeout)."""
    if not rerank_config.get("enabled", False):
        return scored
    t0 = time.time()
    try:
        from reranker import rerank_results
        scored = await rerank_results(query, scored, rerank_config)
    except (ImportError, OSError) as e:
        if _RUNE_TRACE:
            print("[echo-search] reranking error: %s" % e, file=sys.stderr)
    _trace("reranking", t0)
    return scored


async def pipeline_search(
    conn: sqlite3.Connection,
    query: str,
    limit: int,
    layer: Optional[str] = None,
    role: Optional[str] = None,
    context_files: Optional[List[str]] = None,
    category: Optional[str] = None,
    domain: Optional[str] = None,
) -> List[Dict[str, Any]]:
    """Multi-pass retrieval: decompose -> BM25 -> score -> expand -> retry -> rerank."""
    talisman = _load_talisman()
    pipeline_start = time.time()
    overfetch_limit = min(limit * 3, 150)

    facets = await _pipeline_decompose(
        query, _get_echoes_config(talisman, "decomposition"))
    candidates = _pipeline_bm25_search(
        conn, facets, overfetch_limit, layer, role, category, domain)

    t0 = time.time()
    scored = compute_composite_score(
        candidates, _SCORING_WEIGHTS, conn=conn,
        context_files=context_files)
    _trace("composite_scoring", t0)

    _populate_related_entries(scored, conn, category)

    scored = _pipeline_group_expansion(
        conn, scored, _get_echoes_config(talisman, "semantic_groups"),
        context_files)
    scored = _pipeline_retry_injection(
        conn, query, scored,
        _get_echoes_config(talisman, "retry"), context_files)
    scored = await _pipeline_rerank(
        query, scored, _get_echoes_config(talisman, "reranking"))

    _trace("pipeline_total", pipeline_start)
    return scored[:limit]



def build_fts_query(raw_query):
    """Convert a raw search string into a safe FTS5 MATCH expression.

    Tokenizes, strips stopwords, and joins with OR.  Returns an empty
    string when no usable tokens remain (caller should short-circuit).
    """
    # type: (str) -> str
    raw_query = raw_query[:500]  # SEC-7: cap input length
    tokens = re.findall(r"[a-zA-Z0-9_]+", raw_query.lower())
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


def get_stats(conn):
    """Return summary statistics about the echo search index.

    Returns a dict with total entry count, breakdown by layer and role,
    and the last-indexed timestamp.
    """
    # type: (sqlite3.Connection) -> Dict
    total = conn.execute("SELECT COUNT(*) FROM echo_entries").fetchone()[0]

    by_layer = {}  # type: Dict[str, int]
    for row in conn.execute(
        "SELECT layer, COUNT(*) as cnt FROM echo_entries GROUP BY layer"
    ):
        by_layer[row["layer"]] = row["cnt"]

    by_role = {}  # type: Dict[str, int]
    for row in conn.execute(
        "SELECT role, COUNT(*) as cnt FROM echo_entries GROUP BY role"
    ):
        by_role[row["role"]] = row["cnt"]

    by_category = {}  # type: Dict[str, int]
    try:
        for row in conn.execute(
            "SELECT category, COUNT(*) as cnt FROM echo_entries GROUP BY category"
        ):
            by_category[row["category"] or "general"] = row["cnt"]
    except sqlite3.OperationalError:
        pass  # Pre-V3 schema without category column

    archived_count = 0
    try:
        archived_count = conn.execute(
            "SELECT COUNT(*) FROM echo_entries WHERE archived = 1"
        ).fetchone()[0]
    except sqlite3.OperationalError:
        pass  # Pre-V3 schema without archived column

    last_row = conn.execute(
        "SELECT value FROM echo_meta WHERE key='last_indexed'"
    ).fetchone()
    last_indexed = last_row[0] if last_row else ""

    return {
        "total_entries": total,
        "by_layer": by_layer,
        "by_role": by_role,
        "by_category": by_category,
        "archived_count": archived_count,
        "last_indexed": last_indexed,
    }


# ---------------------------------------------------------------------------
# Observations auto-promotion
# ---------------------------------------------------------------------------
#
# Observations entries auto-promote to Inscribed after reaching 3 access_count
# references in echo_access_log (C1 concern: depends on Task 2).
# Promotion rewrites the H2 header in the source MEMORY.md file from
# "## Observations" to "## Inscribed".
#
# C3 concern (CRITICAL): Atomic file rewrite — read full file -> modify
# in-memory -> write to temp file -> os.replace(tmp, original). os.replace()
# is POSIX-atomic (rename syscall), so readers never see a partial write.

_PROMOTION_THRESHOLD = 3  # access_count >= 3 triggers promotion
_OBSERVATIONS_HEADER_RE = re.compile(
    r"^(##\s+)Observations(\s*[\u2014\-\u2013]+\s*.+)$"
)


def _collect_promote_lines(
    entry_ids_to_promote: set, entry_line_map: Dict[str, int],
) -> set:
    """Collect line numbers that need promotion from entry IDs."""
    promote_lines = set()  # type: set
    for eid in entry_ids_to_promote:
        line_num = entry_line_map.get(eid)
        if line_num is not None:
            promote_lines.add(line_num)
    return promote_lines


def _read_memory_file(memory_file: str) -> Optional[List[str]]:
    """Read a MEMORY.md file, returning lines or None on failure."""
    if not os.access(memory_file, os.W_OK):
        print(
            "Warning: Observations promotion skipped — file not writable: %s"
            % memory_file,
            file=sys.stderr,
        )
        return None
    try:
        with open(memory_file, "r", encoding="utf-8") as f:
            return f.readlines()
    except OSError as exc:
        print(
            "Warning: Observations promotion — cannot read %s: %s"
            % (memory_file, exc),
            file=sys.stderr,
        )
        return None


def _try_promote_exact(
    lines: List[str], idx: int, promoted_indices: set,
) -> bool:
    """Try promoting an exact line index. Returns True if promoted."""
    if not (0 <= idx < len(lines)):
        return False
    match = _OBSERVATIONS_HEADER_RE.match(lines[idx].rstrip("\n"))
    if match and idx not in promoted_indices:
        lines[idx] = match.group(1) + "Inscribed" + match.group(2) + "\n"
        promoted_indices.add(idx)
        return True
    return False


def _try_promote_drift(
    lines: List[str], idx: int, promoted_indices: set,
    drift_window: int = 10,
) -> bool:
    """TOME-004: Drift fallback — scan nearby lines for header."""
    for offset in range(1, drift_window + 1):
        for candidate_idx in (idx - offset, idx + offset):
            if candidate_idx < 0 or candidate_idx >= len(lines):
                continue
            if candidate_idx in promoted_indices:
                continue
            match = _OBSERVATIONS_HEADER_RE.match(
                lines[candidate_idx].rstrip("\n"))
            if match:
                lines[candidate_idx] = (
                    match.group(1) + "Inscribed" + match.group(2) + "\n")
                promoted_indices.add(candidate_idx)
                return True
    return False


def _atomic_write_file(memory_file: str, lines: List[str]) -> bool:
    """C3: Atomic rewrite via temp file + os.replace(). Returns success."""
    file_dir = os.path.dirname(memory_file)
    try:
        fd, tmp_path = tempfile.mkstemp(
            dir=file_dir, prefix=".promote-", suffix=".md")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as tmp_f:
                tmp_f.writelines(lines)
            os.replace(tmp_path, memory_file)
        except BaseException:
            try:
                os.unlink(tmp_path)
            except OSError:
                pass
            raise
    except OSError as exc:
        print(
            "Warning: Observations promotion — atomic write failed for %s: %s"
            % (memory_file, exc),
            file=sys.stderr,
        )
        return False
    return True


def _promote_observations_in_file(
    memory_file: str,
    entry_ids_to_promote: set,
    entry_line_map: Dict[str, int],
) -> int:
    """Rewrite Observations headers to Inscribed in a MEMORY.md file.

    Uses atomic file rewrite (C3 concern).

    Args:
        memory_file: Absolute path to the MEMORY.md file.
        entry_ids_to_promote: Set of entry IDs qualifying for promotion.
        entry_line_map: Mapping of entry_id -> line_number.

    Returns:
        Number of entries promoted in this file.
    """
    promote_lines = _collect_promote_lines(
        entry_ids_to_promote, entry_line_map)
    if not promote_lines:
        return 0

    lines = _read_memory_file(memory_file)
    if lines is None:
        return 0

    promoted = 0
    promoted_indices = set()  # type: set
    for target_line in sorted(promote_lines):
        idx = target_line - 1  # 0-indexed
        if _try_promote_exact(lines, idx, promoted_indices):
            promoted += 1
        elif _try_promote_drift(lines, idx, promoted_indices):
            promoted += 1

    if promoted == 0:
        return 0
    if not _atomic_write_file(memory_file, lines):
        return 0
    return promoted


def _fetch_observations_entries(
    conn: sqlite3.Connection,
) -> Tuple[list, Dict[str, int]]:
    """Fetch Observations entries and their access counts.

    Returns (obs_entries, access_counts) or ([], {}) if none found.
    """
    cursor = conn.execute(
        """SELECT e.id, e.file_path, e.line_number
           FROM echo_entries e WHERE e.layer = 'observations'""")
    obs_entries = cursor.fetchall()
    if not obs_entries:
        return [], {}

    entry_ids = [row["id"] for row in obs_entries]
    capped_ids = entry_ids[:200]
    count_cursor = conn.execute(
        """SELECT entry_id, COUNT(*) AS cnt
           FROM echo_access_log
           WHERE entry_id IN (%s)
           GROUP BY entry_id""" % _in_clause(len(capped_ids)),
        capped_ids,
    )
    access_counts = {
        row["entry_id"]: row["cnt"] for row in count_cursor.fetchall()
    }  # type: Dict[str, int]
    return obs_entries, access_counts


def _build_promote_by_file(
    obs_entries: list, access_counts: Dict[str, int],
) -> Dict[str, tuple]:
    """Group promotion candidates by file path."""
    promote_by_file = {}  # type: Dict[str, tuple]
    for row in obs_entries:
        eid, fpath = row["id"], row["file_path"]
        if access_counts.get(eid, 0) >= _PROMOTION_THRESHOLD:
            if fpath not in promote_by_file:
                promote_by_file[fpath] = (set(), {})
            promote_by_file[fpath][0].add(eid)
            promote_by_file[fpath][1][eid] = row["line_number"]
    return promote_by_file


def _validate_and_promote_file(
    fpath: str, ids_to_promote: set, line_map: Dict[str, int],
    real_echo_dir: str,
) -> int:
    """Validate path is inside echo_dir and promote entries."""
    real_fpath = os.path.realpath(fpath)
    try:
        common = os.path.commonpath([real_echo_dir, real_fpath])
    except ValueError:
        return 0
    if common != real_echo_dir:
        print(
            "Warning: Skipping promotion for path outside echo_dir: %s"
            % fpath, file=sys.stderr)
        return 0
    # SEC-003: Use real_fpath (symlinks resolved) so the atomic write and
    # tempfile.mkstemp operate on the verified, canonical path.
    return _promote_observations_in_file(real_fpath, ids_to_promote, line_map)


def _write_dirty_signal(echo_dir: str) -> None:
    """EDGE-021: Trigger dirty signal after promotion."""
    sig_path = _signal_path(echo_dir)
    if sig_path:
        try:
            os.makedirs(os.path.dirname(sig_path), exist_ok=True)
            with open(sig_path, "w") as f:
                f.write("promoted")
        except OSError:
            pass


# ---------------------------------------------------------------------------
# Global dirty signal (enrichment D4)
# ---------------------------------------------------------------------------
# Global echoes use a dedicated signal path at GLOBAL_ECHO_DIR/.global-echo-dirty
# instead of deriving via _signal_path(), because the global echo directory
# has no project root to derive from.

_GLOBAL_DIRTY_FILENAME = ".global-echo-dirty"


def _global_dirty_path() -> str:
    """Return the global dirty signal file path, or empty string if disabled."""
    if not GLOBAL_ECHO_DIR:
        return ""
    return os.path.join(GLOBAL_ECHO_DIR, _GLOBAL_DIRTY_FILENAME)


def _check_and_clear_global_dirty() -> bool:
    """Return True (and delete the file) if the global dirty signal is present."""
    path = _global_dirty_path()
    if not path:
        return False
    try:
        if os.path.isfile(path):
            os.remove(path)
            return True
    except OSError:
        pass  # Race with another consumer or permission issue — safe to ignore
    return False


def _write_global_dirty_signal() -> None:
    """Write the global dirty signal file."""
    path = _global_dirty_path()
    if not path:
        return
    try:
        os.makedirs(os.path.dirname(path), exist_ok=True)
        with open(path, "w") as f:
            f.write("dirty")
    except OSError:
        pass


def _check_promotions(echo_dir: str, db_path: str) -> int:
    """Promote eligible Observations to Inscribed (pre-reindex)."""
    if not echo_dir or not db_path:
        return 0

    conn = get_db(db_path)
    try:
        ensure_schema(conn)
        obs_entries, access_counts = _fetch_observations_entries(conn)
        if not obs_entries:
            return 0

        promote_by_file = _build_promote_by_file(obs_entries, access_counts)
        total_promoted = 0
        real_echo_dir = os.path.realpath(echo_dir)
        for fpath, (ids_to_promote, line_map) in promote_by_file.items():
            total_promoted += _validate_and_promote_file(
                fpath, ids_to_promote, line_map, real_echo_dir)

        if total_promoted > 0:
            # Use appropriate dirty signal based on scope
            if GLOBAL_ECHO_DIR and os.path.realpath(echo_dir) == os.path.realpath(GLOBAL_ECHO_DIR):
                _write_global_dirty_signal()
            else:
                _write_dirty_signal(echo_dir)

    except sqlite3.OperationalError as exc:
        print(
            "Warning: Observations promotion check failed: %s" % exc,
            file=sys.stderr,
        )
        return 0
    finally:
        conn.close()

    return total_promoted


# ---------------------------------------------------------------------------
# Reindex helper (used by both CLI and MCP tool)
# ---------------------------------------------------------------------------

def do_reindex(echo_dir: str, db_path: str) -> Dict[str, Any]:
    """Re-parse MEMORY.md files, auto-promote Observations, rebuild FTS index."""
    from indexer import discover_and_parse

    start_ms = int(time.time() * 1000)

    # Auto-promote eligible Observations to Inscribed BEFORE parsing.
    # This ensures promoted entries are indexed with their new layer name.
    promotions = _check_promotions(echo_dir, db_path)

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


# ---------------------------------------------------------------------------
# MCP tool schemas (raw dicts — converted to types.Tool inside run_mcp_server)
# ---------------------------------------------------------------------------

TOOL_SCHEMAS = [
    {
        "name": "echo_search",
        "description": (
            "Search the Rune echo system for learnings, patterns, "
            "and insights using BM25 full-text search."
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
                    "description": "Search query (natural language or keywords)",
                },
                "limit": {
                    "type": "integer",
                    "description": "Max results to return (default 10, max 50)",
                    "default": 10,
                },
                "offset": {
                    "type": "integer",
                    "description": "Number of results to skip for pagination (default 0)",
                    "default": 0,
                },
                "layer": {
                    "type": "string",
                    "description": "Filter by echo layer (e.g., inscribed)",
                },
                "role": {
                    "type": "string",
                    "description": "Filter by role (e.g., orchestrator, reviewer, planner)",
                },
                "context_files": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": (
                        "Optional list of currently open/edited file paths "
                        "for proximity scoring"
                    ),
                },
                "category": {
                    "type": "string",
                    "enum": ["general", "pattern", "anti-pattern", "decision", "debugging"],
                    "description": "Filter by entry category",
                },
                "response_format": {
                    "type": "string",
                    "enum": ["json", "markdown"],
                    "description": "Output format: json (default, structured) or markdown (human-readable)",
                    "default": "json",
                },
                "scope": {
                    "type": "string",
                    "enum": ["project", "global", "all"],
                    "default": "project",
                    "description": (
                        "Search scope: project echoes only (default), "
                        "global echoes + doc packs, or both"
                    ),
                },
                "domain": {
                    "type": "string",
                    "enum": [
                        "backend", "frontend", "devops", "database",
                        "testing", "architecture", "general",
                    ],
                    "description": (
                        "Filter global results by domain tag. "
                        "Only effective with scope=global or scope=all."
                    ),
                },
            },
            "required": ["query"],
        },
    },
    {
        "name": "echo_details",
        "description": "Fetch full content for specific echo entries by their IDs.",
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
        "inputSchema": {
            "type": "object",
            "properties": {
                "ids": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "List of entry IDs to fetch",
                },
                "scope": {
                    "type": "string",
                    "enum": ["project", "global", "all"],
                    "default": "project",
                    "description": (
                        "Which DB to query: project (default), global, "
                        "or both (falls back to global if not found in project)"
                    ),
                },
            },
            "required": ["ids"],
        },
    },
    {
        "name": "echo_reindex",
        "description": "Re-parse all MEMORY.md files and rebuild the search index.",
        "annotations": {
            "readOnlyHint": False,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
        "inputSchema": {
            "type": "object",
            "properties": {
                "scope": {
                    "type": "string",
                    "enum": ["project", "global", "all"],
                    "default": "project",
                    "description": (
                        "Which index to rebuild: project (default), "
                        "global, or both"
                    ),
                },
            },
            "required": [],
        },
    },
    {
        "name": "echo_stats",
        "description": "Get summary statistics about the echo search index.",
        "annotations": {
            "readOnlyHint": True,
            "destructiveHint": False,
            "idempotentHint": True,
            "openWorldHint": False,
        },
        "inputSchema": {
            "type": "object",
            "properties": {
                "scope": {
                    "type": "string",
                    "enum": ["project", "global", "all"],
                    "default": "project",
                    "description": (
                        "Which index to report on: project (default), "
                        "global, or both"
                    ),
                },
            },
            "required": [],
        },
    },
    {
        "name": "echo_record_access",
        "description": (
            "Manually record access events for specific echo entry IDs. "
            "Normally access is auto-recorded on search, but this tool "
            "allows explicit recording (e.g., when an entry is viewed)."
        ),
        "annotations": {
            "readOnlyHint": False,
            "destructiveHint": False,
            "idempotentHint": False,
            "openWorldHint": False,
        },
        "inputSchema": {
            "type": "object",
            "properties": {
                "entry_ids": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "List of echo entry IDs to record access for",
                },
                "query": {
                    "type": "string",
                    "description": "Optional context query that led to this access",
                    "default": "",
                },
                "scope": {
                    "type": "string",
                    "enum": ["project", "global"],
                    "default": "project",
                    "description": (
                        "Which DB to record access in: project (default) "
                        "or global"
                    ),
                },
            },
            "required": ["entry_ids"],
        },
    },
    {
        "name": "echo_upsert_group",
        "description": (
            "Create or update a semantic group of echo entries. "
            "Groups cluster related entries for expanded retrieval."
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
                "group_id": {
                    "type": "string",
                    "description": "Group identifier (16-char hex). Auto-generated if omitted.",
                },
                "entry_ids": {
                    "type": "array",
                    "items": {"type": "string"},
                    "description": "List of echo entry IDs to include in the group",
                },
                "similarities": {
                    "type": "array",
                    "items": {"type": "number"},
                    "description": "Optional similarity scores per entry (default 0.0)",
                },
            },
            "required": ["entry_ids"],
        },
    },
]


# ---------------------------------------------------------------------------
# MCP tool handlers (module-level — return (data_dict, is_error) tuples)
# ---------------------------------------------------------------------------


def _get_ready_conn(
    db_path: str, echo_dir: str, *, reindex_on_dirty: bool = True,
) -> sqlite3.Connection:
    """Open a DB connection, ensure schema, and reindex if dirty or empty.

    Consolidates the repeated connect-check-reindex pattern used by
    multiple MCP handlers.  Callers are responsible for closing the
    returned connection.
    """
    conn = get_db(db_path)
    ensure_schema(conn)
    if not reindex_on_dirty or not echo_dir:
        return conn
    count = conn.execute(
        "SELECT COUNT(*) FROM echo_entries").fetchone()[0]
    is_dirty = _check_and_clear_dirty(echo_dir)
    if count == 0 or is_dirty:
        conn.close()
        try:
            do_reindex(echo_dir, db_path)
        except (sqlite3.Error, OSError, IOError) as exc:
            logger.warning(
                "reindex failed, proceeding with %s index: %s",
                "empty" if count == 0 else "stale", exc,
            )
        conn = get_db(db_path)
    return conn


def _validate_list_arg(arguments, key, required=True):
    """Validate a list argument from MCP tool input.

    Returns ``(validated_list, error_tuple_or_None)``.  When the error
    tuple is not ``None`` the caller should return it immediately.
    """
    # type: (Dict, str, bool) -> Tuple
    val = arguments.get(key, [])
    if not isinstance(val, list):
        return None, ({"error": "%s must be a list" % key}, True)
    if required and not val:
        return None, ({"error": "%s is required" % key}, True)
    return val, None


_VALID_LAYERS = frozenset(_LAYER_IMPORTANCE.keys())
_SAFE_ROLE_RE = re.compile(r"^[a-zA-Z0-9_-]{1,64}$")
_VALID_CATEGORIES = frozenset(
    {"general", "pattern", "anti-pattern", "decision", "debugging"})
_VALID_SCOPES = frozenset({"project", "global", "all"})
_VALID_DOMAINS = frozenset(
    {"backend", "frontend", "devops", "database",
     "testing", "architecture", "general"})


def _sanitize_search_filters(arguments: Dict) -> Dict[str, Any]:
    """Sanitize optional filter fields for echo_search.

    Returns a dict with layer, role, context_files, category, scope, and
    domain — invalid values coerced to ``None`` (or default).
    """
    # SEC-008: Allowlist validation — layer must be a known echo tier;
    # role must match safe identifier pattern (alphanumeric + hyphens/underscores).
    layer = arguments.get("layer")
    if layer is not None:
        if not isinstance(layer, str) or layer.lower() not in _VALID_LAYERS:
            layer = None
    role = arguments.get("role")
    if role is not None:
        if not isinstance(role, str) or not _SAFE_ROLE_RE.match(role):
            role = None
    context_files = arguments.get("context_files")
    if context_files is not None:
        if not isinstance(context_files, list):
            context_files = None
        else:
            context_files = [
                str(f) for f in context_files[:20]
                if isinstance(f, str) and f] or None
    category = arguments.get("category")
    if category is not None:
        if not isinstance(category, str) or category.lower() not in _VALID_CATEGORIES:
            category = None
        else:
            category = category.lower()
    scope = arguments.get("scope", "project")
    if not isinstance(scope, str) or scope not in _VALID_SCOPES:
        scope = "project"
    domain = arguments.get("domain")
    if domain is not None:
        if not isinstance(domain, str) or domain.lower() not in _VALID_DOMAINS:
            domain = None
        else:
            domain = domain.lower()
    return {"layer": layer, "role": role, "context_files": context_files,
            "category": category, "scope": scope, "domain": domain}


def _validate_search_args(arguments: Dict) -> Tuple[Optional[Tuple], Dict]:
    """Validate and sanitize echo_search arguments. Returns (error, cleaned)."""
    query = arguments.get("query", "")
    if not isinstance(query, str) or not query:
        return ({"error": "query must be a non-empty string"}, True), {}
    filters = _sanitize_search_filters(arguments)
    limit = arguments.get("limit", 10)
    if not isinstance(limit, int) or limit < 1:
        limit = 10
    limit = min(limit, 50)
    offset = arguments.get("offset", 0)
    if not isinstance(offset, int) or offset < 0:
        offset = 0
    response_format = arguments.get("response_format", "json")
    if response_format not in ("json", "markdown"):
        response_format = "json"
    return None, {"query": query, "limit": limit, "offset": offset,
                  "response_format": response_format, **filters}


def _format_search_markdown(entries, total_count, offset, limit, has_more):
    """Format search results as a human-readable markdown string."""
    # type: (List[Dict], int, int, int, bool) -> str
    lines = ["## Echo Search Results", ""]
    lines.append("**%d results** (showing %d-%d of %d)%s" % (
        len(entries), offset + 1, offset + len(entries), total_count,
        " | *more available*" if has_more else ""))
    lines.append("")
    for i, e in enumerate(entries, 1):
        lines.append("### %d. %s" % (i + offset, e.get("id", "?")))
        lines.append("- **Layer**: %s | **Role**: %s | **Score**: %.4f" % (
            e.get("layer", "?"), e.get("role", "?"), e.get("score", 0)))
        if e.get("tags"):
            lines.append("- **Tags**: %s" % e["tags"])
        preview = e.get("content_preview", "")
        if preview:
            lines.append("- %s" % preview)
        lines.append("")
    if has_more:
        lines.append("*Use `offset: %d` to fetch next page.*" % (offset + limit))
    return "\n".join(lines)


def _build_search_response(
    results: List[Dict],
    total_candidates: int,
    offset: int,
    limit: int,
    has_more: bool,
    response_format: str,
) -> Tuple[Dict, bool]:
    """Build the final search response dict in JSON or markdown format."""
    if response_format == "markdown":
        md = _format_search_markdown(
            results, total_candidates, offset, limit, has_more)
        return {"text": md}, False
    return {
        "entries": results,
        "total_count": total_candidates,
        "count": len(results),
        "offset": offset,
        "limit": limit,
        "has_more": has_more,
    }, False


async def _search_single_scope(
    conn: sqlite3.Connection,
    args: Dict[str, Any],
    fetch_limit: int,
    source_scope: str,
) -> List[Dict[str, Any]]:
    """Run pipeline_search on a single DB and tag results with source_scope."""
    domain = args.get("domain") if source_scope == "global" else None
    results = await pipeline_search(
        conn, args["query"], fetch_limit,
        args["layer"], args["role"], args["context_files"],
        args.get("category"), domain)
    for r in results:
        r["source_scope"] = source_scope
    # NOTE: Doc-pack importance discount is applied at the factor level
    # in _compute_entry_factors() (A3), not post-hoc on composite score.
    return results


def _merge_scoped_results(
    project_results: List[Dict[str, Any]],
    global_results: List[Dict[str, Any]],
    limit: int,
) -> List[Dict[str, Any]]:
    """Merge results from two scopes by composite score, dedup by scoped key.

    BACK-403: Uses scope-prefixed keys ("project:<id>" / "global:<id>") for
    dedup to prevent ID collisions between project and global DBs.  Entries
    with the same raw ID but different scopes are kept as separate results.
    """
    combined = {}  # type: Dict[str, Dict[str, Any]]
    for entry in project_results:
        eid = entry.get("id", "")
        if eid:
            scoped_key = "project:" + eid
            combined[scoped_key] = entry
    for entry in global_results:
        eid = entry.get("id", "")
        if eid:
            scoped_key = "global:" + eid
            if scoped_key not in combined or (
                    entry.get("composite_score", 0.0) >
                    combined[scoped_key].get("composite_score", 0.0)):
                combined[scoped_key] = entry
    return sorted(
        combined.values(),
        key=lambda x: x.get("composite_score", 0.0), reverse=True,
    )[:limit]


async def _mcp_handle_search(arguments: Dict) -> Tuple[Dict, bool]:
    """Handle echo_search — validate, run pipeline, record access."""
    err, args = _validate_search_args(arguments)
    if err is not None:
        return err[0], err[1]
    offset = args["offset"]
    fetch_limit = args["limit"] + offset
    scope = args.get("scope", "project")

    all_results = await _run_scoped_search(args, fetch_limit + 1, scope)

    total_candidates = len(all_results)
    has_more = total_candidates > fetch_limit
    results = all_results[offset:fetch_limit]
    _safe_record_access(results, args["query"], scope)
    return _build_search_response(
        results, total_candidates, offset, args["limit"],
        has_more, args["response_format"])


async def _run_scoped_search(
    args: Dict[str, Any], fetch_limit: int, scope: str,
) -> List[Dict[str, Any]]:
    """Execute search across the requested scope(s)."""
    project_results = []  # type: List[Dict[str, Any]]
    global_results = []  # type: List[Dict[str, Any]]

    if scope in ("project", "all"):
        conn = _get_ready_conn(DB_PATH, ECHO_DIR)
        try:
            project_results = await _search_single_scope(
                conn, args, fetch_limit, "project")
        finally:
            conn.close()

    if scope in ("global", "all"):
        # BACK-201: Guard — return error when scope=global but global DB unavailable
        if not GLOBAL_ECHO_DIR or not GLOBAL_DB_PATH:
            if scope == "global":
                return [{"error": "Global echoes not configured (GLOBAL_ECHO_DIR/GLOBAL_DB_PATH not set)",
                         "source_scope": "global"}]
            # scope=all: silently skip global, use project only
        else:
            # BACK-402: Check GLOBAL_DB_PATH availability FIRST, then consume
            # dirty signal. Previous order consumed the signal before the guard,
            # losing it when GLOBAL_DB_PATH was unset.
            if _check_and_clear_global_dirty():
                try:
                    do_reindex(GLOBAL_ECHO_DIR, GLOBAL_DB_PATH)
                except (sqlite3.Error, OSError, IOError) as exc:
                    logger.warning("global reindex failed: %s", exc)
                # Reset cached connection so it picks up the fresh index
                global _global_conn
                if _global_conn is not None:
                    try:
                        _global_conn.close()
                    except Exception:
                        pass
                    _global_conn = None
            gconn = get_global_conn()
            if gconn is not None:
                global_results = await _search_single_scope(
                    gconn, args, fetch_limit, "global")
            elif scope == "global":
                return [{"error": "Global DB connection failed",
                         "source_scope": "global"}]

    if scope == "all" and project_results and global_results:
        return _merge_scoped_results(
            project_results, global_results, fetch_limit)
    if scope == "global":
        return global_results
    if scope == "all":
        return project_results or global_results
    return project_results


def _safe_record_access(
    results: List[Dict[str, Any]], query: str, scope: str,
) -> None:
    """Record access events, routing to the correct DB per result scope."""
    project_entries = [r for r in results
                       if r.get("source_scope", "project") == "project"]
    global_entries = [r for r in results
                      if r.get("source_scope") == "global"]
    if project_entries and scope in ("project", "all"):
        try:
            conn = get_db(DB_PATH)
            try:
                _record_access(conn, project_entries, query)
            finally:
                conn.close()
        except (sqlite3.Error, OSError) as exc:
            logger.debug("project access log write failed: %s", exc)
    if global_entries and scope in ("global", "all"):
        try:
            gconn = get_global_conn()
            if gconn is not None:
                _record_access(gconn, global_entries, query)
        except (sqlite3.Error, OSError) as exc:
            logger.debug("global access log write failed: %s", exc)


async def _mcp_handle_details(arguments: Dict) -> Tuple[Dict, bool]:
    """Handle echo_details — fetch full content for specific entry IDs.

    QUAL-001: Supports scope parameter. When scope=all, entries not found
    in project DB are looked up in global DB as fallback.
    """
    ids, err = _validate_list_arg(arguments, "ids")
    if err is not None:
        return err
    ids = ids[:50]  # SEC-1: cap to prevent DoS via large IN clause
    scope = arguments.get("scope", "project")
    if not isinstance(scope, str) or scope not in _VALID_SCOPES:
        scope = "project"

    results = []  # type: List[Dict[str, Any]]

    if scope in ("project", "all"):
        conn = _get_ready_conn(DB_PATH, ECHO_DIR)
        try:
            results = get_details(conn, ids)
        finally:
            conn.close()

    if scope in ("global", "all"):
        gconn = get_global_conn()
        if gconn is not None:
            if scope == "global":
                results = get_details(gconn, ids)
            elif scope == "all":
                # Fallback: look up IDs not found in project DB
                found_ids = {r["id"] for r in results}
                missing_ids = [i for i in ids if i not in found_ids]
                if missing_ids:
                    global_results = get_details(gconn, missing_ids)
                    for r in global_results:
                        r["source_scope"] = "global"
                    results.extend(global_results)
        elif scope == "global":
            return {"error": "Global echoes not configured"}, True

    return {"entries": results}, False


async def _mcp_handle_reindex(arguments: Optional[Dict] = None) -> Tuple[Dict, bool]:
    """Handle echo_reindex — rebuild FTS5 index from MEMORY.md sources.

    Supports scope parameter (project|global|all, default project).
    """
    args = arguments or {}
    scope = args.get("scope", "project")
    if not isinstance(scope, str) or scope not in _VALID_SCOPES:
        scope = "project"

    results = {}  # type: Dict[str, Any]

    if scope in ("project", "all"):
        if not ECHO_DIR:
            if scope == "project":
                return {"error": "ECHO_DIR not set"}, True
        else:
            results["project"] = do_reindex(ECHO_DIR, DB_PATH)

    if scope in ("global", "all"):
        if not GLOBAL_ECHO_DIR or not GLOBAL_DB_PATH:
            if scope == "global":
                return {"error": "GLOBAL_ECHO_DIR not set"}, True
        else:
            # BACK-303: Validate global and project echo dirs don't overlap
            # to prevent scope contamination during reindex.
            if ECHO_DIR and os.path.realpath(GLOBAL_ECHO_DIR) == os.path.realpath(ECHO_DIR):
                return {"error": "GLOBAL_ECHO_DIR must differ from ECHO_DIR"}, True
            results["global"] = do_reindex(GLOBAL_ECHO_DIR, GLOBAL_DB_PATH)

    # Backward compat: if single scope, return flat result
    if len(results) == 1:
        return next(iter(results.values())), False
    return results, False


async def _mcp_handle_stats(arguments: Optional[Dict] = None) -> Tuple[Dict, bool]:
    """Handle echo_stats — return index summary statistics.

    Supports scope parameter (project|global|all, default project).
    """
    args = arguments or {}
    scope = args.get("scope", "project")
    if not isinstance(scope, str) or scope not in _VALID_SCOPES:
        scope = "project"

    results = {}  # type: Dict[str, Any]

    if scope in ("project", "all"):
        conn = get_db(DB_PATH)
        try:
            ensure_schema(conn)
            results["project"] = get_stats(conn)
        finally:
            conn.close()

    if scope in ("global", "all"):
        gconn = get_global_conn()
        if gconn is not None:
            results["global"] = get_stats(gconn)
        elif scope == "global":
            return {"error": "Global echoes not configured"}, True

    # Backward compat: if single scope, return flat result
    if len(results) == 1:
        return next(iter(results.values())), False
    return results, False


async def _mcp_handle_record_access(arguments):
    """Handle echo_record_access — manually record access events.

    QUAL-003: Supports scope parameter for routing to global DB.
    """
    # type: (Dict) -> Tuple[Dict, bool]
    entry_ids, err = _validate_list_arg(arguments, "entry_ids")
    if err is not None:
        return err
    query = arguments.get("query", "")
    if not isinstance(query, str):
        query = ""
    scope = arguments.get("scope", "project")
    if not isinstance(scope, str) or scope not in ("project", "global"):
        scope = "project"
    entry_ids = [str(eid) for eid in entry_ids if eid is not None][:50]
    pseudo_results = [{"id": eid} for eid in entry_ids]

    if scope == "global":
        gconn = get_global_conn()
        if gconn is None:
            return {"error": "Global echoes not configured"}, True
        _record_access(gconn, pseudo_results, query)
    else:
        conn = get_db(DB_PATH)
        try:
            ensure_schema(conn)
            _record_access(conn, pseudo_results, query)
        finally:
            conn.close()
    return {"recorded": len(entry_ids), "entry_ids": entry_ids,
            "scope": scope}, False


async def _mcp_handle_upsert_group(arguments):
    """Handle echo_upsert_group — create or update a semantic group."""
    # type: (Dict) -> Tuple[Dict, bool]
    entry_ids, err = _validate_list_arg(arguments, "entry_ids")
    if err is not None:
        return err
    group_id = arguments.get("group_id", "")
    similarities = arguments.get("similarities")
    entry_ids = [str(eid) for eid in entry_ids if eid is not None][:50]
    if not isinstance(group_id, str) or not group_id:
        group_id = uuid.uuid4().hex[:16]
    if similarities is not None:
        if not isinstance(similarities, list):
            similarities = None
        else:
            similarities = [
                float(s) if isinstance(s, (int, float)) else 0.0
                for s in similarities[:len(entry_ids)]
            ]
            if len(similarities) < len(entry_ids):
                similarities.extend([0.0] * (len(entry_ids) - len(similarities)))
    conn = get_db(DB_PATH)
    try:
        ensure_schema(conn)
        try:
            count = upsert_semantic_group(conn, group_id, entry_ids, similarities)
        except ValueError as exc:
            return {"error": str(exc)}, True
    finally:
        conn.close()
    return {"group_id": group_id, "memberships": count, "entry_ids": entry_ids}, False


# Handler dispatch table
_MCP_HANDLERS = {
    "echo_search": _mcp_handle_search,
    "echo_details": _mcp_handle_details,
    "echo_reindex": _mcp_handle_reindex,
    "echo_stats": _mcp_handle_stats,
    "echo_record_access": _mcp_handle_record_access,
    "echo_upsert_group": _mcp_handle_upsert_group,
}


# ---------------------------------------------------------------------------
# MCP Server
# ---------------------------------------------------------------------------


def _validate_mcp_env():
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


def _register_mcp_handlers(server, types):
    """Register list_tools and call_tool handlers on the MCP server."""

    @server.list_tools()
    async def handle_list_tools():
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
    async def handle_call_tool(name, arguments):
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


def run_mcp_server():
    """Launch the Echo Search MCP stdio server.

    Validates environment, imports MCP dependencies, registers handlers,
    and runs the async loop.
    """
    _validate_mcp_env()
    import asyncio
    import mcp.server.stdio
    import mcp.types as types
    from mcp.server.lowlevel import Server, NotificationOptions
    from mcp.server.models import InitializationOptions
    server = Server("echo-search")
    _register_mcp_handlers(server, types)

    async def _run():
        async with mcp.server.stdio.stdio_server() as (read_stream, write_stream):
            await server.run(
                read_stream, write_stream,
                InitializationOptions(
                    server_name="echo-search", server_version="1.54.0",
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

def main_cli():
    """CLI entry point — run as MCP server or perform a standalone reindex."""
    # type: () -> None
    parser = argparse.ArgumentParser(
        description="Echo Search MCP Server"
    )
    parser.add_argument(
        "--reindex",
        action="store_true",
        help="Reindex all MEMORY.md files and exit",
    )
    args = parser.parse_args()

    if args.reindex:
        if not ECHO_DIR:
            print("Error: ECHO_DIR environment variable not set", file=sys.stderr)
            sys.exit(1)
        if not DB_PATH:
            print("Error: DB_PATH environment variable not set", file=sys.stderr)
            sys.exit(1)

        result = do_reindex(ECHO_DIR, DB_PATH)
        print("Indexed %d entries in %dms" % (result["entries_indexed"], result["time_ms"]))
        print("Roles: %s" % ", ".join(result["roles"]))
        sys.exit(0)

    # Default: run as MCP stdio server
    if not DB_PATH:
        print("Error: DB_PATH environment variable not set", file=sys.stderr)
        sys.exit(1)

    run_mcp_server()


if __name__ == "__main__":
    main_cli()
