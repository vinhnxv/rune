"""Observations auto-promotion for Echo Search.

Promotes Observations-tier echo entries to Inscribed after reaching
a configurable access-count threshold (default: 3 references in
echo_access_log).  Promotion rewrites the ``## Observations`` H2 header
in the source MEMORY.md file to ``## Inscribed`` using an atomic
file-rewrite strategy (temp file + os.replace).

Functions:
    check_promotions           — Top-level entry point: promote eligible entries.
    promote_observations_in_file — Rewrite headers in a single MEMORY.md file.

Internal helpers:
    _collect_promote_lines, _read_memory_file, _try_promote_exact,
    _try_promote_drift, _atomic_write_file, _fetch_observations_entries,
    _build_promote_by_file, _validate_and_promote_file, _write_dirty_signal
"""

from __future__ import annotations

import logging
import os
import re
import sqlite3
import sys
import tempfile
from typing import Dict, List, Optional, Tuple

logger = logging.getLogger("echo-search")

# ---------------------------------------------------------------------------
# Lazy imports to avoid circular dependencies during decomposition.
# These will resolve to config/database modules once extraction is complete.
# ---------------------------------------------------------------------------


def _get_server_helpers():
    """Lazy import of utility helpers from server module."""
    from server import (
        _in_clause,
        _signal_path,
        _global_dirty_path,
        _write_global_dirty_signal,
        GLOBAL_ECHO_DIR,
    )
    return _in_clause, _signal_path, _global_dirty_path, _write_global_dirty_signal, GLOBAL_ECHO_DIR


def _get_database():
    """Lazy import of database helpers."""
    from database import get_db, ensure_schema
    return get_db, ensure_schema


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
    _in_clause = _get_server_helpers()[0]
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
    _, _signal_path, _, _, _ = _get_server_helpers()
    sig_path = _signal_path(echo_dir)
    if sig_path:
        try:
            os.makedirs(os.path.dirname(sig_path), exist_ok=True)
            with open(sig_path, "w") as f:
                f.write("promoted")
        except OSError:
            pass


def check_promotions(echo_dir: str, db_path: str) -> int:
    """Promote eligible Observations to Inscribed (pre-reindex).

    Opens a temporary database connection, fetches Observations entries,
    checks access counts against _PROMOTION_THRESHOLD, and rewrites
    qualifying MEMORY.md file headers atomically.

    Args:
        echo_dir: Path to the echoes directory.
        db_path: Path to the SQLite database file.

    Returns:
        Total number of entries promoted.
    """
    if not echo_dir or not db_path:
        return 0

    get_db, ensure_schema = _get_database()
    _, _, _, _write_global_dirty_signal, GLOBAL_ECHO_DIR = _get_server_helpers()

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
