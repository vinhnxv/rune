"""
Composite scoring for echo search results.

5-factor re-ranking system that scores search results using a weighted blend of:
  1. Relevance  — normalized BM25 score (0.0-1.0)
  2. Importance — layer-based weight (Etched > Inscribed > Traced)
  3. Recency    — exponential decay based on entry age (layer-aware)
  4. Proximity  — file proximity to current context (evidence path extraction)
  5. Frequency  — access frequency from echo_access_log (log-scaled)

BM25 sign convention: SQLite FTS5 bm25() returns NEGATIVE values where
more negative = more relevant. We normalize via min-max scaling:
  normalized = (bm25_max - bm25_i) / (bm25_max - bm25_min)
This inverts the sign so 1.0 = most relevant, 0.0 = least relevant.

The log(1+count) formula for frequency scoring uses a logarithmic scale
to prevent high-access entries from dominating — diminishing returns
after the first few accesses.

Weights are configurable via ECHO_WEIGHT_* environment variables and
auto-normalized to sum to 1.0.
"""
from __future__ import annotations

import logging
import math
import os
import re
import sqlite3
import sys
import time
from datetime import datetime, timezone
from typing import Any, Dict, List, Optional, Tuple

from config import _in_clause

logger = logging.getLogger("echo-search")


# ---------------------------------------------------------------------------
# Composite scoring — 5-factor re-ranking
# ---------------------------------------------------------------------------

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

    # Pre-compute normalized context paths and their directories for O(1) lookups,
    # avoiding the O(E*C) nested loop for the two most common proximity tiers.
    ctx_norms = {os.path.normpath(ctx) for ctx in context_files}
    ctx_dirs = {os.path.dirname(p) for p in ctx_norms if os.path.dirname(p)}

    best = 0.0
    for ev in evidence_paths:
        # Tier 1: exact match — O(1) set lookup
        if ev in ctx_norms:
            return 1.0

        # Tier 2: same directory — O(1) set lookup
        ev_dir = os.path.dirname(ev)
        if ev_dir and ev_dir in ctx_dirs:
            best = max(best, 0.8)
            continue  # Can't beat 0.8 for this ev without exact match

        # Tier 3: shared prefix — must compare against each context path
        if best < 0.8:
            for ctx_norm in ctx_norms:
                score = compute_file_proximity(ev, ctx_norm)
                if score > best:
                    best = score
                if best >= 0.8:
                    break  # No need to check more context paths for this ev

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
            WHERE id IN (
                SELECT id FROM echo_access_log
                ORDER BY accessed_at ASC
                LIMIT (SELECT MAX(0, COUNT(*) - 90000) FROM echo_access_log))""")
        conn.commit()


def _record_access(
    conn: sqlite3.Connection,
    results: List[Dict[str, Any]],
    query: str,
) -> None:
    """Record access events using batch operations (PERF-004, PERF-005).

    Uses executemany() for INSERT and a single UPDATE ... WHERE IN for
    unarchiving, replacing the previous per-entry loop.
    """
    if not results:
        return
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    truncated_query = query[:500]
    try:
        # Collect valid entry IDs (cap at 200 consistent with _get_access_counts)
        entry_ids = [e.get("id", "") for e in results if e.get("id")][:200]
        if not entry_ids:
            return

        # Batch INSERT all access records (PERF-004)
        conn.executemany(
            "INSERT INTO echo_access_log "
            "(entry_id, accessed_at, query) VALUES (?, ?, ?)",
            [(eid, now, truncated_query) for eid in entry_ids],
        )

        # BACK-014: Batch unarchive accessed entries (PERF-005)
        placeholders = ",".join("?" for _ in entry_ids)
        conn.execute(
            "UPDATE echo_entries SET archived = 0 "
            "WHERE archived = 1 AND id IN (%s)" % placeholders,
            entry_ids,
        )

        conn.commit()
        _cap_access_log(conn)
    except sqlite3.OperationalError as exc:
        conn.rollback()
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
