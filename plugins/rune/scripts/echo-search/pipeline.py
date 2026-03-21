"""
Multi-pass retrieval pipeline for echo search.

Orchestrates a 7-stage search pipeline:
  1. Query decomposition (async, via decomposer module)
  2. Per-facet BM25 search
  3. Facet result merging
  4. Composite scoring (5-factor re-ranking)
  5. Semantic group expansion
  6. Retry injection (failed entry re-discovery)
  7. Haiku reranking (async, via reranker module)

Also includes retry tracking with token fingerprinting for entries that
failed to match in previous searches (EDGE-016 through EDGE-020).

Lazy imports: decomposer and reranker modules are imported inside their
respective pipeline stage functions to avoid import-time failures when
those optional dependencies are unavailable.
"""
from __future__ import annotations

import hashlib
import logging
import re
import sqlite3
import sys
import time
from typing import Any, Dict, List, Optional, Tuple

from config import (
    STOPWORDS,
    _get_echoes_config,
    _in_clause,
    _load_talisman,
    _RUNE_TRACE,
    _trace,
)
from grouping import expand_semantic_groups
from scoring import _SCORING_WEIGHTS, compute_composite_score
from search import search_entries

logger = logging.getLogger("echo-search")


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


def _build_entry_group_map(
    group_rows: list,
) -> tuple:
    """Build entry_id -> group_ids mapping from semantic_groups query rows.

    Returns (entry_groups dict, all_group_ids set).
    """
    entry_groups = {}  # type: Dict[str, set]
    all_group_ids = set()  # type: set
    for row in group_rows:
        eid, gid = row[0], row[1]
        entry_groups.setdefault(eid, set()).add(gid)
        all_group_ids.add(gid)
    return entry_groups, all_group_ids


def _build_group_member_map(
    conn: sqlite3.Connection,
    gid_list: list,
    category_filter: Optional[str] = None,
) -> Optional[Dict[str, List[Dict[str, Any]]]]:
    """Fetch group members from DB and build group_id -> member list mapping.

    Returns None on schema error (pre-V2 compat). Excludes archived entries.
    """
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
        return None
    group_members = {}  # type: Dict[str, List[Dict[str, Any]]]
    for row in member_rows:
        member = {"id": row[1], "tags": row[2], "layer": row[3], "role": row[4]}
        group_members.setdefault(row[0], []).append(member)
    return group_members


def _collect_related_for_entry(
    entry_id: str,
    entry_groups: Dict[str, set],
    group_members: Dict[str, List[Dict[str, Any]]],
    result_id_set: frozenset,
) -> list:
    """Collect related entries for a single entry via group co-membership.

    Returns up to 10 related entry dicts, excluding the entry itself
    and other result entries.
    """
    groups = entry_groups.get(entry_id, set())
    related = {}  # type: Dict[str, Dict[str, Any]]
    for gid in groups:
        for member in group_members.get(gid, []):
            mid = member["id"]
            if mid != entry_id and mid not in result_id_set and mid not in related:
                related[mid] = member
    return list(related.values())[:10]


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
    entry_groups, all_group_ids = _build_entry_group_map(group_rows)
    group_members = _build_group_member_map(conn, list(all_group_ids), category_filter)
    if group_members is None:
        for r in results:
            r["related_entries"] = []
        return
    for r in results:
        r["related_entries"] = _collect_related_for_entry(
            r.get("id", ""), entry_groups, group_members, result_id_set
        )


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
