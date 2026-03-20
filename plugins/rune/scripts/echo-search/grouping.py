"""Semantic grouping for echo search entries.

Provides Jaccard-similarity-based grouping of echo entries, group assignment
to the ``semantic_groups`` SQLite table, upsert operations, and group expansion
for search result enrichment.

Functions are organized into six logical clusters:

1. **Tokenization** — ``_tokenize_for_grouping``, ``_evidence_basenames``
2. **Similarity** — ``compute_entry_similarity``
3. **Group building** — ``_merge_pair_into_groups``, ``_build_pairwise_groups``,
   ``_chunk_groups``, ``_write_groups``
4. **Assignment** — ``assign_semantic_groups``, ``_validate_and_filter_entries``
5. **Upsert** — ``upsert_semantic_group``
6. **Expansion** — ``_fetch_group_ids``, ``_fetch_expanded_rows``,
   ``_rows_to_expanded_entries``, ``_dedup_expanded``,
   ``_merge_scored_results``, ``_apply_expansion_discount``,
   ``expand_semantic_groups``
"""

from __future__ import annotations

import logging
import os
import re
import sqlite3
import time
import uuid
from typing import Any, Dict, List, Optional

from config import STOPWORDS, _in_clause

logger = logging.getLogger("echo-search")

# Regex for extracting file paths from echo content.
# Matches backtick-fenced tokens that look like file paths (contain / and end
# with a common extension).
_EVIDENCE_PATH_RE = re.compile(r'`([^`]+\.[a-z]{1,6})`')


# ---------------------------------------------------------------------------
# 1. Tokenization
# ---------------------------------------------------------------------------


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


# ---------------------------------------------------------------------------
# 2. Similarity
# ---------------------------------------------------------------------------


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


# ---------------------------------------------------------------------------
# 3. Group building
# ---------------------------------------------------------------------------


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
    if len(entry_ids) < 2:
        return []
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


# ---------------------------------------------------------------------------
# 4. Assignment
# ---------------------------------------------------------------------------


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


def _validate_and_filter_entries(
    conn: sqlite3.Connection,
    entry_ids: list[str],
    similarities: list[float],
) -> tuple:
    """Validate entry_ids exist in DB and filter to existing ones.

    Returns (filtered_pairs, skipped_ids) where filtered_pairs is
    list of (entry_id, similarity) tuples for existing entries.
    """
    existing = frozenset(
        r[0] for r in conn.execute(
            "SELECT id FROM echo_entries WHERE id IN (%s)"
            % _in_clause(len(entry_ids)),
            entry_ids,
        ).fetchall()
    )
    skipped = [eid for eid in entry_ids if eid not in existing]
    filtered = [
        (eid, sim) for eid, sim in zip(entry_ids, similarities)
        if eid in existing
    ]
    return filtered, skipped


# ---------------------------------------------------------------------------
# 5. Upsert
# ---------------------------------------------------------------------------


def upsert_semantic_group(
    conn: sqlite3.Connection, group_id: str,
    entry_ids: list[str], similarities: list[float] | None = None,
) -> int:
    """Insert or replace semantic group memberships (INSERT OR REPLACE).

    Validates that all entry_ids exist in echo_entries before inserting.
    Returns count of memberships created. Raises ValueError for length mismatch.
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
    filtered, skipped = _validate_and_filter_entries(conn, entry_ids, similarities)
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


# ---------------------------------------------------------------------------
# 6. Expansion
# ---------------------------------------------------------------------------


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

    # Late import to avoid circular dependency — compute_composite_score
    # remains in server.py (or scoring.py once extracted).
    from server import compute_composite_score

    scored_expanded = compute_composite_score(
        unique, weights, conn=conn, context_files=context_files)
    _apply_expansion_discount(scored_expanded, discount)
    return _merge_scored_results(scored_results, scored_expanded)
