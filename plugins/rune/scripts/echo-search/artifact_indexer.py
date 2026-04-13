"""Arc artifact indexer for the Echo Search MCP server.

Scans .rune/arc-history/*/ and indexes arc run artifacts (TOME findings,
resolution reports, work summaries, gap analyses, inspect verdicts) into
a separate SQLite FTS5 table for cross-session recall.

Each indexed entry uses a deterministic SHA-256 ID (same pattern as
indexer.py's generate_id()) keyed on arc_id:artifact_type:entry_index.

Supported artifact types
------------------------
- tome          — TOME.md / tome.md: RUNE:FINDING blocks
- resolution    — resolution-report.md: per-finding fix status
- work_summary  — work-summary.md: task completion and decisions
- gap_analysis  — gap-analysis.md: gap IDs, categories, statuses
- inspect_verdict — inspect-verdict.md / VERDICT.md: dimension scores

Functions
---------
do_artifact_reindex(arc_history_dir, db_path) — full reindex of arc-history
"""

from __future__ import annotations

import hashlib
import json
import logging
import os
import re
import sqlite3
from typing import Any, Dict, List, Tuple

logger = logging.getLogger("echo-search")

# ---------------------------------------------------------------------------
# Constants
# ---------------------------------------------------------------------------

# Artifact filenames to scan per arc run directory (order matters — first match wins)
_ARTIFACT_FILES: Dict[str, List[str]] = {
    "tome": ["tome.md", "TOME.md"],
    "resolution": ["resolution-report.md"],
    "work_summary": ["work-summary.md"],
    "gap_analysis": ["gap-analysis.md"],
    "inspect_verdict": ["inspect-verdict.md", "VERDICT.md"],
}

# All entries from arc artifacts are "inscribed" layer — persisted tactical memory
_ARTIFACT_LAYER = "inscribed"

# SEC-002: Valid arc_id pattern
_VALID_ARC_ID_RE = re.compile(r"^arc-[a-zA-Z0-9_-]+$")

# Max artifact file size (10 MB) — SEC-P2-005 parity with indexer.py
_MAX_FILE_BYTES = 10 * 1024 * 1024

# ---------------------------------------------------------------------------
# ID generation (matches indexer.py generate_id() pattern)
# ---------------------------------------------------------------------------


def generate_artifact_id(arc_id: str, artifact_type: str, entry_index: int) -> str:
    """Generate a deterministic 16-char hex ID for an artifact entry.

    Uses SHA-256 of ``{arc_id}:{artifact_type}:{entry_index}`` — same
    truncation pattern as indexer.py's generate_id() for consistency.

    Args:
        arc_id: Arc run identifier (e.g. ``arc-1776106675852``).
        artifact_type: One of the five supported artifact types.
        entry_index: Zero-based entry index within the artifact file.

    Returns:
        16-character lowercase hex string.
    """
    raw = "%s:%s:%d" % (arc_id, artifact_type, entry_index)
    return hashlib.sha256(raw.encode("utf-8")).hexdigest()[:16]


# ---------------------------------------------------------------------------
# Per-artifact parsers (defensive — try/except per entry)
# ---------------------------------------------------------------------------

# RUNE:FINDING comment anchor: <!-- RUNE:FINDING id="..." severity="P1/P2/P3" file="..." ... -->
_FINDING_COMMENT_RE = re.compile(
    r'<!--\s*RUNE:FINDING\s+([^>]+)-->'
)
_ATTR_RE = re.compile(r'(\w+)="([^"]*)"')

# Finding heading: ### FINDING-ID (P1): Description text
_FINDING_HEADING_RE = re.compile(
    r'^###\s+([\w-]+)\s+\((P[123])\)\s*:\s*(.+)$',
    re.MULTILINE,
)

# File path in finding body: - **File**: `path/to/file`
_FILE_LINE_RE = re.compile(r'\*\*File\*\*:\s*`([^`]+)`')


def _parse_tome(content: str, arc_id: str, date: str) -> List[Dict[str, Any]]:
    """Parse TOME.md content into indexed entries.

    Extracts RUNE:FINDING blocks using both the structured HTML comment anchors
    and the heading text for content. Each finding becomes one entry.

    Args:
        content: Full TOME file content.
        arc_id: Parent arc run identifier.
        date: ISO-8601 date string from meta.json.

    Returns:
        List of entry dicts ready for upsert into artifact_entries.
    """
    entries: List[Dict[str, Any]] = []
    idx = 0

    # Split on finding headings to extract per-finding blocks
    heading_positions = [(m.start(), m) for m in _FINDING_HEADING_RE.finditer(content)]
    comment_index: Dict[str, Dict[str, str]] = {}

    # Index comment anchors by finding ID for fast lookup
    for m in _FINDING_COMMENT_RE.finditer(content):
        attrs = dict(_ATTR_RE.findall(m.group(1)))
        fid = attrs.get("id", "")
        if fid:
            comment_index[fid] = attrs

    for i, (start_pos, heading_match) in enumerate(heading_positions):
        try:
            finding_id = heading_match.group(1)
            severity = heading_match.group(2)
            description = heading_match.group(3).strip()

            # Block text: from this heading to next heading (or end)
            end_pos = heading_positions[i + 1][0] if i + 1 < len(heading_positions) else len(content)
            block_text = content[start_pos:end_pos].strip()

            # Extract file path from finding body
            file_path = ""
            file_match = _FILE_LINE_RE.search(block_text)
            if file_match:
                file_path = file_match.group(1)

            # Prefer file from comment anchor if available
            comment_attrs = comment_index.get(finding_id, {})
            if comment_attrs.get("file"):
                file_path = comment_attrs["file"]
            if not severity and comment_attrs.get("severity"):
                severity = comment_attrs["severity"]

            # Build searchable content: description + block body
            entry_content = description + "\n\n" + block_text

            entry: Dict[str, Any] = {
                "id": generate_artifact_id(arc_id, "tome", idx),
                "arc_id": arc_id,
                "artifact_type": "tome",
                "role": "arc-tome",
                "layer": _ARTIFACT_LAYER,
                "date": date,
                "content": entry_content,
                "tags": "tome " + severity.lower() + " " + (finding_id.split("-")[0].lower() if "-" in finding_id else finding_id.lower()),
                "severity": severity,
                "finding_id": finding_id,
                "file_path": file_path,
                "plan_file": "",
            }
            entries.append(entry)
            idx += 1
        except Exception as exc:  # noqa: BLE001
            logger.warning("tome parser: skipping entry %d in %s: %s", idx, arc_id, exc)
            idx += 1

    return entries


def _parse_resolution(content: str, arc_id: str, date: str) -> List[Dict[str, Any]]:
    """Parse resolution-report.md into indexed entries.

    Extracts per-finding resolution status using HTML comment markers.

    Actual format:
        <!-- RESOLVED:DOC-001:FIXED -->
        ### DOC-001: title
        **Status**: FIXED
        ...
        <!-- /RESOLVED:DOC-001 -->

    Args:
        content: Full resolution report file content.
        arc_id: Parent arc run identifier.
        date: ISO-8601 date string from meta.json.

    Returns:
        List of entry dicts.
    """
    entries: List[Dict[str, Any]] = []
    idx = 0

    # Match <!-- RESOLVED:ID:STATUS --> ... <!-- /RESOLVED:ID --> blocks
    _resolved_block_re = re.compile(
        r'<!--\s*RESOLVED:([\w-]+):([\w]+)\s*-->(.*?)<!--\s*/RESOLVED:\1\s*-->',
        re.DOTALL,
    )

    for m in _resolved_block_re.finditer(content):
        try:
            finding_id = m.group(1).strip()
            resolution_status = m.group(2).strip().upper()
            block_text = m.group(0).strip()

            entry: Dict[str, Any] = {
                "id": generate_artifact_id(arc_id, "resolution", idx),
                "arc_id": arc_id,
                "artifact_type": "resolution",
                "role": "arc-resolution",
                "layer": _ARTIFACT_LAYER,
                "date": date,
                "content": block_text,
                "tags": "resolution " + resolution_status.lower() + " " + finding_id.lower(),
                "severity": "",
                "finding_id": finding_id,
                "file_path": "",
                "plan_file": "",
            }
            entries.append(entry)
            idx += 1
        except Exception as exc:  # noqa: BLE001
            logger.warning("resolution parser: skipping entry %d in %s: %s", idx, arc_id, exc)
            idx += 1

    # Fallback: if no structured entries found, index the whole file as one entry
    if not entries and content.strip():
        try:
            entries.append({
                "id": generate_artifact_id(arc_id, "resolution", 0),
                "arc_id": arc_id,
                "artifact_type": "resolution",
                "role": "arc-resolution",
                "layer": _ARTIFACT_LAYER,
                "date": date,
                "content": content[:5000],
                "tags": "resolution",
                "severity": "",
                "finding_id": "",
                "file_path": "",
                "plan_file": "",
            })
        except Exception as exc:  # noqa: BLE001
            logger.warning("resolution fallback: failed for %s: %s", arc_id, exc)

    return entries


def _parse_work_summary(content: str, arc_id: str, date: str) -> List[Dict[str, Any]]:
    """Parse work-summary.md into indexed entries.

    Extracts task completion status sections and key decisions.

    Args:
        content: Full work summary file content.
        arc_id: Parent arc run identifier.
        date: ISO-8601 date string from meta.json.

    Returns:
        List of entry dicts.
    """
    entries: List[Dict[str, Any]] = []
    idx = 0

    # Match task headings: "### Task N: Description" or "## Task N"
    _task_re = re.compile(
        r'^#{2,3}\s+(?:Task\s+\d+|TASK-\d+)[:\s]+(.+)$',
        re.IGNORECASE | re.MULTILINE,
    )

    heading_positions = [(m.start(), m) for m in _task_re.finditer(content)]

    for i, (start_pos, m) in enumerate(heading_positions):
        try:
            task_desc = m.group(1).strip()
            end_pos = heading_positions[i + 1][0] if i + 1 < len(heading_positions) else len(content)
            block_text = content[start_pos:end_pos].strip()

            # Detect completion status from block content
            completion = ""
            if re.search(r'\b(COMPLETED?|DONE|finished)\b', block_text, re.IGNORECASE):
                completion = "completed"
            elif re.search(r'\b(FAILED?|ERROR|SKIPPED?)\b', block_text, re.IGNORECASE):
                completion = "failed"
            elif re.search(r'\b(PARTIAL|IN.PROGRESS)\b', block_text, re.IGNORECASE):
                completion = "partial"

            entry: Dict[str, Any] = {
                "id": generate_artifact_id(arc_id, "work_summary", idx),
                "arc_id": arc_id,
                "artifact_type": "work_summary",
                "role": "arc-work-summary",
                "layer": _ARTIFACT_LAYER,
                "date": date,
                "content": block_text,
                "tags": "work-summary " + completion + " " + task_desc[:50].lower(),
                "severity": "",
                "finding_id": "",
                "file_path": "",
                "plan_file": "",
            }
            entries.append(entry)
            idx += 1
        except Exception as exc:  # noqa: BLE001
            logger.warning("work_summary parser: skipping entry %d in %s: %s", idx, arc_id, exc)
            idx += 1

    # Fallback: index whole file
    if not entries and content.strip():
        try:
            entries.append({
                "id": generate_artifact_id(arc_id, "work_summary", 0),
                "arc_id": arc_id,
                "artifact_type": "work_summary",
                "role": "arc-work-summary",
                "layer": _ARTIFACT_LAYER,
                "date": date,
                "content": content[:5000],
                "tags": "work-summary",
                "severity": "",
                "finding_id": "",
                "file_path": "",
                "plan_file": "",
            })
        except Exception as exc:  # noqa: BLE001
            logger.warning("work_summary fallback: failed for %s: %s", arc_id, exc)

    return entries


def _parse_gap_analysis(content: str, arc_id: str, date: str) -> List[Dict[str, Any]]:
    """Parse gap-analysis.md into indexed entries.

    Extracts AC IDs with their statuses from pipe-delimited compliance matrices.

    Actual format:
        | AC | Description | Status | Evidence |
        |----|-------------|--------|----------|
        | AC-1 | Description text | COMPLETE | Evidence |

    Args:
        content: Full gap analysis file content.
        arc_id: Parent arc run identifier.
        date: ISO-8601 date string from meta.json.

    Returns:
        List of entry dicts.
    """
    entries: List[Dict[str, Any]] = []
    idx = 0

    # Match pipe-delimited table rows with at least 4 columns
    _table_row_re = re.compile(
        r'^\|([^|\n]+)\|([^|\n]+)\|([^|\n]+)\|([^|\n]*)\|',
        re.MULTILINE,
    )
    # Separator rows contain only dashes, colons, and pipes
    _sep_re = re.compile(r'^[-:\s]+$')
    # Known header column names (skip these rows)
    _header_first_cols = frozenset({"ac", "requirement", "gap id", "id", "criterion"})

    for m in _table_row_re.finditer(content):
        try:
            ac_id = m.group(1).strip()
            description = m.group(2).strip()
            status = m.group(3).strip()
            evidence = m.group(4).strip()

            # Skip separator rows (e.g. |----|)
            if _sep_re.match(ac_id):
                continue
            # Skip header rows
            if ac_id.lower() in _header_first_cols:
                continue
            # Skip rows where the status column is a header name
            if status.lower() in ("status", "evidence", "score", "description"):
                continue
            # Skip rows that are clearly not data (no recognisable AC/gap ID)
            if not ac_id:
                continue

            prefix = ac_id.split("-")[0].lower() if "-" in ac_id else "ac"
            entry_content = (
                description
                + "\n\nStatus: " + status
                + ("\n\nEvidence: " + evidence if evidence else "")
            ).strip()

            entry: Dict[str, Any] = {
                "id": generate_artifact_id(arc_id, "gap_analysis", idx),
                "arc_id": arc_id,
                "artifact_type": "gap_analysis",
                "role": "arc-gap-analysis",
                "layer": _ARTIFACT_LAYER,
                "date": date,
                "content": entry_content,
                "tags": "gap-analysis " + prefix + " " + status.lower(),
                "severity": "",
                "finding_id": ac_id,
                "file_path": "",
                "plan_file": "",
            }
            entries.append(entry)
            idx += 1
        except Exception as exc:  # noqa: BLE001
            logger.warning("gap_analysis parser: skipping entry %d in %s: %s", idx, arc_id, exc)
            idx += 1

    # Fallback: index whole file
    if not entries and content.strip():
        try:
            entries.append({
                "id": generate_artifact_id(arc_id, "gap_analysis", 0),
                "arc_id": arc_id,
                "artifact_type": "gap_analysis",
                "role": "arc-gap-analysis",
                "layer": _ARTIFACT_LAYER,
                "date": date,
                "content": content[:5000],
                "tags": "gap-analysis",
                "severity": "",
                "finding_id": "",
                "file_path": "",
                "plan_file": "",
            })
        except Exception as exc:  # noqa: BLE001
            logger.warning("gap_analysis fallback: failed for %s: %s", arc_id, exc)

    return entries


def _parse_inspect_verdict(content: str, arc_id: str, date: str) -> List[Dict[str, Any]]:
    """Parse inspect-verdict.md / VERDICT.md into indexed entries.

    Extracts dimension scores and requirement statuses from table rows.

    Actual format (Dimension Scores table):
        | Dimension | Score | Status |
        |-----------|-------|--------|
        | Correctness | 95% | All 5 ACs implemented |

    Actual format (Requirement Matrix table):
        | Requirement | Status | Evidence |
        |-------------|--------|----------|
        | AC-1: Loop | COMPLETE | SKILL.md:L14 ... |

    Args:
        content: Full inspect verdict file content.
        arc_id: Parent arc run identifier.
        date: ISO-8601 date string from meta.json.

    Returns:
        List of entry dicts.
    """
    entries: List[Dict[str, Any]] = []
    idx = 0

    # Overall verdict from file content: READY / GAPS_FOUND / CRITICAL_ISSUES etc.
    _verdict_re = re.compile(
        r'\b(READY|READY_PARTIAL|GAPS_FOUND|INCOMPLETE|CRITICAL_ISSUES)\b',
        re.IGNORECASE,
    )
    overall_verdict = ""
    verdict_match = _verdict_re.search(content)
    if verdict_match:
        overall_verdict = verdict_match.group(1).upper()

    # Match pipe-delimited table rows with at least 3 columns
    _table_row_re = re.compile(
        r'^\|([^|\n]+)\|([^|\n]+)\|([^|\n]*)\|',
        re.MULTILINE,
    )
    # Separator rows
    _sep_re = re.compile(r'^[-:\s]+$')
    # Header column names to skip
    _header_first_cols = frozenset({
        "dimension", "requirement", "metric", "gap", "finding",
        "criterion", "aspect", "category",
    })

    for m in _table_row_re.finditer(content):
        try:
            col0 = m.group(1).strip()   # dimension name / requirement
            col1 = m.group(2).strip()   # score / status
            col2 = m.group(3).strip()   # description / evidence

            # Skip separator rows
            if _sep_re.match(col0):
                continue
            # Skip header rows
            if col0.lower() in _header_first_cols:
                continue
            if col1.lower() in ("score", "status", "value"):
                continue
            if not col0:
                continue

            entry_content = (
                col0
                + " | " + col1
                + (" | " + col2 if col2 else "")
            )

            entry: Dict[str, Any] = {
                "id": generate_artifact_id(arc_id, "inspect_verdict", idx),
                "arc_id": arc_id,
                "artifact_type": "inspect_verdict",
                "role": "arc-inspect-verdict",
                "layer": _ARTIFACT_LAYER,
                "date": date,
                "content": entry_content,
                "tags": "inspect-verdict " + overall_verdict.lower() + " " + col0[:40].lower(),
                "severity": "",
                "finding_id": "",
                "file_path": "",
                "plan_file": "",
            }
            entries.append(entry)
            idx += 1
        except Exception as exc:  # noqa: BLE001
            logger.warning("inspect_verdict parser: skipping entry %d in %s: %s", idx, arc_id, exc)
            idx += 1

    # Fallback: index whole file as single entry for overall verdict
    if not entries and content.strip():
        try:
            entries.append({
                "id": generate_artifact_id(arc_id, "inspect_verdict", 0),
                "arc_id": arc_id,
                "artifact_type": "inspect_verdict",
                "role": "arc-inspect-verdict",
                "layer": _ARTIFACT_LAYER,
                "date": date,
                "content": content[:5000],
                "tags": "inspect-verdict " + overall_verdict.lower(),
                "severity": "",
                "finding_id": "",
                "file_path": "",
                "plan_file": "",
            })
        except Exception as exc:  # noqa: BLE001
            logger.warning("inspect_verdict fallback: failed for %s: %s", arc_id, exc)

    return entries


# Registry: artifact_type → parser function
_PARSERS = {
    "tome": _parse_tome,
    "resolution": _parse_resolution,
    "work_summary": _parse_work_summary,
    "gap_analysis": _parse_gap_analysis,
    "inspect_verdict": _parse_inspect_verdict,
}


# ---------------------------------------------------------------------------
# Arc run directory scanner
# ---------------------------------------------------------------------------


def _read_arc_meta(arc_dir: str) -> Dict[str, str]:
    """Read meta.json from an arc history directory.

    Returns a dict with at least ``date`` and ``plan_file`` keys.
    Falls back to empty strings on parse failure.

    Args:
        arc_dir: Path to one arc run directory inside .rune/arc-history/.

    Returns:
        Dict with ``arc_id``, ``date``, and ``plan_file`` keys.
    """
    meta_path = os.path.join(arc_dir, "meta.json")
    defaults: Dict[str, str] = {"arc_id": os.path.basename(arc_dir), "date": "", "plan_file": ""}
    if not os.path.isfile(meta_path):
        return defaults
    try:
        with open(meta_path, "r", encoding="utf-8") as f:
            meta = json.load(f)
        if isinstance(meta, dict):
            defaults["arc_id"] = str(meta.get("arc_id", defaults["arc_id"]))
            defaults["date"] = str(meta.get("date", ""))
            defaults["plan_file"] = str(meta.get("plan_file", ""))
    except (OSError, ValueError, UnicodeDecodeError) as exc:
        logger.warning("meta.json read failed for %s: %s", arc_dir, exc)
    return defaults


def _parse_arc_run(arc_dir: str) -> List[Dict[str, Any]]:
    """Parse all artifact files in one arc run directory.

    Iterates over the five artifact types, finds the first matching filename,
    reads the file (with size guard), and calls the appropriate parser.

    Args:
        arc_dir: Absolute path to one arc run directory.

    Returns:
        Flat list of entry dicts for all artifacts in this run.
    """
    meta = _read_arc_meta(arc_dir)
    arc_id = meta["arc_id"]
    date = meta["date"]
    plan_file = meta["plan_file"]

    all_entries: List[Dict[str, Any]] = []

    for artifact_type, filenames in _ARTIFACT_FILES.items():
        for filename in filenames:
            fpath = os.path.join(arc_dir, filename)
            if not os.path.isfile(fpath):
                continue

            # SEC-P2-005: reject oversized files
            try:
                if os.path.getsize(fpath) > _MAX_FILE_BYTES:
                    logger.warning(
                        "artifact too large, skipping: %s (> %d MB)",
                        fpath, _MAX_FILE_BYTES // (1024 * 1024),
                    )
                    break
            except OSError:
                break

            try:
                with open(fpath, "r", encoding="utf-8") as f:
                    content = f.read()
            except (OSError, UnicodeDecodeError) as exc:
                logger.warning("cannot read %s: %s", fpath, exc)
                break

            parser = _PARSERS.get(artifact_type)
            if parser is None:
                break

            try:
                entries = parser(content, arc_id, date)
            except Exception as exc:  # noqa: BLE001
                logger.warning(
                    "parser %s raised unexpectedly for %s: %s",
                    artifact_type, arc_dir, exc,
                )
                entries = []

            # Stamp plan_file onto all entries from this run
            for e in entries:
                if plan_file:
                    e["plan_file"] = plan_file

            all_entries.extend(entries)
            break  # First matching filename wins — don't parse both TOME.md and tome.md

    return all_entries


# ---------------------------------------------------------------------------
# Reindex entry point
# ---------------------------------------------------------------------------


def _upsert_entries(
    conn: sqlite3.Connection, entries: List[Dict[str, Any]]
) -> Tuple[int, int]:
    """Upsert artifact entries into the artifact_entries table.

    Uses INSERT OR REPLACE to handle reruns idempotently (same ID = same
    arc_id:artifact_type:idx, so reindexing is stable).

    Args:
        conn: Open SQLite connection with artifact_entries table.
        entries: List of entry dicts from the parsers.

    Returns:
        Tuple of (inserted_count, skipped_count).
    """
    inserted = 0
    skipped = 0

    for e in entries:
        try:
            conn.execute(
                """INSERT OR REPLACE INTO artifact_entries
                   (id, arc_id, artifact_type, role, layer, date, content,
                    tags, severity, finding_id, file_path, plan_file)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (
                    e["id"],
                    e["arc_id"],
                    e["artifact_type"],
                    e.get("role", "arc-" + e["artifact_type"]),
                    e.get("layer", _ARTIFACT_LAYER),
                    e.get("date", ""),
                    e["content"],
                    e.get("tags", ""),
                    e.get("severity", ""),
                    e.get("finding_id", ""),
                    e.get("file_path", ""),
                    e.get("plan_file", ""),
                ),
            )
            inserted += 1
        except (sqlite3.Error, KeyError, TypeError) as exc:
            logger.warning("upsert skipped entry %s: %s", e.get("id", "?"), exc)
            skipped += 1

    return inserted, skipped


def do_artifact_reindex(arc_history_dir: str, db_path: str) -> Dict[str, Any]:
    """Reindex all arc-history artifacts into the artifact SQLite database.

    Scans every subdirectory of ``arc_history_dir`` that passes the
    SEC-002 arc_id validation pattern, parses all known artifact types,
    and upserts entries into the ``artifact_entries`` + FTS5 table.

    This function is the primary entry point called by the MCP handler
    ``_get_ready_artifact_conn()`` when the ``.artifact-dirty`` signal
    is detected.

    Args:
        arc_history_dir: Path to ``.rune/arc-history/`` directory.
        db_path: Path to the artifact SQLite database file (artifacts.db).

    Returns:
        Dict with ``indexed``, ``skipped``, ``arc_runs``, and ``errors`` counts.
    """
    # Import here to avoid circular dependency (database imports config, not artifact_indexer)
    from database import get_db, ensure_artifact_schema

    stats: Dict[str, Any] = {"indexed": 0, "skipped": 0, "arc_runs": 0, "errors": 0}

    if not os.path.isdir(arc_history_dir):
        logger.debug("arc_history_dir not found, nothing to index: %s", arc_history_dir)
        return stats

    conn = get_db(db_path)
    try:
        ensure_artifact_schema(conn)

        # Clear existing entries for a full rebuild (simple + reliable vs incremental)
        conn.execute("BEGIN IMMEDIATE")
        try:
            conn.execute("DELETE FROM artifact_entries")
            conn.commit()
        except sqlite3.Error as exc:
            conn.rollback()
            logger.warning("failed to clear artifact_entries: %s", exc)
            raise

        all_entries: List[Dict[str, Any]] = []

        # Scan arc run subdirectories
        try:
            run_dirs = sorted(os.listdir(arc_history_dir))
        except OSError as exc:
            logger.warning("cannot list arc_history_dir: %s", exc)
            conn.close()
            return stats

        for name in run_dirs:
            # SEC-002: validate arc_id pattern
            if not _VALID_ARC_ID_RE.match(name):
                logger.debug("skipping non-arc directory: %s", name)
                continue

            arc_dir = os.path.join(arc_history_dir, name)
            if not os.path.isdir(arc_dir):
                continue

            # SEC-P2-003: containment check — arc_dir must be under arc_history_dir
            real_arc_dir = os.path.realpath(arc_dir)
            real_history = os.path.realpath(arc_history_dir)
            if not real_arc_dir.startswith(real_history + os.sep):
                logger.warning("symlink escape detected: %s -> %s", arc_dir, real_arc_dir)
                continue

            try:
                entries = _parse_arc_run(arc_dir)
                all_entries.extend(entries)
                stats["arc_runs"] += 1
            except Exception as exc:  # noqa: BLE001
                logger.warning("parse_arc_run failed for %s: %s", name, exc)
                stats["errors"] += 1

        # Batch upsert all entries in a single transaction
        if all_entries:
            conn.execute("BEGIN IMMEDIATE")
            try:
                inserted, skipped = _upsert_entries(conn, all_entries)
                conn.commit()
                stats["indexed"] = inserted
                stats["skipped"] = skipped
            except sqlite3.Error as exc:
                conn.rollback()
                logger.warning("batch upsert failed: %s", exc)
                stats["errors"] += 1

        # Rebuild FTS5 index
        try:
            conn.execute("INSERT INTO artifact_entries_fts(artifact_entries_fts) VALUES('rebuild')")
            conn.commit()
        except sqlite3.Error as exc:
            logger.warning("FTS5 rebuild failed: %s", exc)

    finally:
        conn.close()

    logger.info(
        "artifact reindex: %d indexed, %d skipped, %d arc runs, %d errors",
        stats["indexed"], stats["skipped"], stats["arc_runs"], stats["errors"],
    )
    return stats
