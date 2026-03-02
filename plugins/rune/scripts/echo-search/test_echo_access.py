"""Tests for access frequency tracking in server.py.

Covers:
  - echo_access_log table creation
  - Access recording on search
  - Access count retrieval
  - Orphan handling (EDGE-007)
  - Bounded growth (EDGE-010)
  - Frequency normalization with log scaling
  - Age-based pruning during reindex
"""

import sqlite3
import time

import pytest

from server import (
    _get_access_counts,
    _record_access,
    _score_frequency,
    ensure_schema,
    get_db,
    rebuild_index,
    search_entries,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def db():
    """In-memory SQLite database with schema initialized."""
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    ensure_schema(conn)
    yield conn
    conn.close()


@pytest.fixture
def sample_entries():
    """Sample entries for access tracking tests."""
    return [
        {
            "id": "access_test_entry1",
            "role": "reviewer",
            "layer": "inscribed",
            "date": "2026-02-20",
            "source": "test",
            "content": "Security pattern for access tracking tests",
            "tags": "Access test",
            "line_number": 1,
            "file_path": "/echoes/reviewer/MEMORY.md",
        },
        {
            "id": "access_test_entry2",
            "role": "orchestrator",
            "layer": "etched",
            "date": "2026-02-19",
            "source": "test",
            "content": "Another security finding for validation",
            "tags": "Validation test",
            "line_number": 2,
            "file_path": "/echoes/orchestrator/MEMORY.md",
        },
    ]


@pytest.fixture
def populated_db(db, sample_entries):
    """Database with sample entries indexed."""
    rebuild_index(db, sample_entries)
    return db


# ---------------------------------------------------------------------------
# Schema: echo_access_log table
# ---------------------------------------------------------------------------


class TestAccessLogSchema:
    """Verify the echo_access_log table is created with correct schema."""

    def test_access_log_table_exists(self, db):
        """echo_access_log table is created by ensure_schema."""
        tables = {
            row[0]
            for row in db.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        }
        assert "echo_access_log" in tables

    def test_access_log_has_expected_columns(self, db):
        """echo_access_log has id, entry_id, accessed_at, query columns."""
        info = db.execute("PRAGMA table_info(echo_access_log)").fetchall()
        columns = {row["name"] for row in info}
        assert "id" in columns
        assert "entry_id" in columns
        assert "accessed_at" in columns
        assert "query" in columns

    def test_access_log_entry_id_index_exists(self, db):
        """Index on entry_id exists for fast lookups."""
        indexes = {
            row[1]
            for row in db.execute("PRAGMA index_list(echo_access_log)").fetchall()
        }
        assert "idx_access_log_entry_id" in indexes

    def test_access_log_accessed_at_index_exists(self, db):
        """Index on accessed_at exists for age-based pruning."""
        indexes = {
            row[1]
            for row in db.execute("PRAGMA index_list(echo_access_log)").fetchall()
        }
        assert "idx_access_log_accessed_at" in indexes


# ---------------------------------------------------------------------------
# _record_access
# ---------------------------------------------------------------------------


class TestRecordAccess:
    """Test synchronous access recording."""

    def test_records_access_for_results(self, populated_db):
        """_record_access inserts rows into echo_access_log."""
        results = [
            {"id": "access_test_entry1"},
            {"id": "access_test_entry2"},
        ]
        _record_access(populated_db, results, "test query")

        count = populated_db.execute(
            "SELECT COUNT(*) FROM echo_access_log"
        ).fetchone()[0]
        assert count == 2

    def test_records_query_string(self, populated_db):
        """Recorded access includes the search query."""
        results = [{"id": "access_test_entry1"}]
        _record_access(populated_db, results, "security patterns")

        row = populated_db.execute(
            "SELECT query FROM echo_access_log WHERE entry_id = ?",
            ("access_test_entry1",),
        ).fetchone()
        assert row["query"] == "security patterns"

    def test_records_timestamp(self, populated_db):
        """Recorded access includes an ISO timestamp."""
        results = [{"id": "access_test_entry1"}]
        _record_access(populated_db, results, "test")

        row = populated_db.execute(
            "SELECT accessed_at FROM echo_access_log WHERE entry_id = ?",
            ("access_test_entry1",),
        ).fetchone()
        assert "T" in row["accessed_at"]
        assert row["accessed_at"].endswith("Z")

    def test_empty_results_no_insert(self, populated_db):
        """Empty results list does not insert any rows."""
        _record_access(populated_db, [], "test")
        count = populated_db.execute(
            "SELECT COUNT(*) FROM echo_access_log"
        ).fetchone()[0]
        assert count == 0

    def test_missing_id_skipped(self, populated_db):
        """Results without 'id' key are skipped."""
        results = [{"no_id": "value"}, {"id": "access_test_entry1"}]
        _record_access(populated_db, results, "test")

        count = populated_db.execute(
            "SELECT COUNT(*) FROM echo_access_log"
        ).fetchone()[0]
        assert count == 1

    def test_empty_id_skipped(self, populated_db):
        """Results with empty string 'id' are skipped."""
        results = [{"id": ""}, {"id": "access_test_entry1"}]
        _record_access(populated_db, results, "test")

        count = populated_db.execute(
            "SELECT COUNT(*) FROM echo_access_log"
        ).fetchone()[0]
        assert count == 1

    def test_query_length_capped(self, populated_db):
        """SEC-7: Query string is capped at 500 chars."""
        long_query = "x" * 1000
        results = [{"id": "access_test_entry1"}]
        _record_access(populated_db, results, long_query)

        row = populated_db.execute(
            "SELECT query FROM echo_access_log LIMIT 1"
        ).fetchone()
        assert len(row["query"]) <= 500

    def test_multiple_accesses_accumulate(self, populated_db):
        """Multiple access recordings for the same entry accumulate."""
        results = [{"id": "access_test_entry1"}]
        _record_access(populated_db, results, "query1")
        _record_access(populated_db, results, "query2")
        _record_access(populated_db, results, "query3")

        count = populated_db.execute(
            "SELECT COUNT(*) FROM echo_access_log WHERE entry_id = ?",
            ("access_test_entry1",),
        ).fetchone()[0]
        assert count == 3


# ---------------------------------------------------------------------------
# _get_access_counts
# ---------------------------------------------------------------------------


class TestGetAccessCounts:
    """Test batch access count retrieval."""

    def test_empty_ids_returns_empty(self, populated_db):
        """Empty ID list returns empty dict."""
        assert _get_access_counts(populated_db, []) == {}

    def test_no_accesses_returns_empty(self, populated_db):
        """IDs with no access log entries return empty dict."""
        result = _get_access_counts(populated_db, ["access_test_entry1"])
        assert result == {}

    def test_counts_single_entry(self, populated_db):
        """Returns count for a single entry with accesses."""
        for _ in range(3):
            _record_access(populated_db, [{"id": "access_test_entry1"}], "q")

        counts = _get_access_counts(populated_db, ["access_test_entry1"])
        assert counts["access_test_entry1"] == 3

    def test_counts_multiple_entries(self, populated_db):
        """Returns counts for multiple entries."""
        for _ in range(5):
            _record_access(populated_db, [{"id": "access_test_entry1"}], "q")
        for _ in range(2):
            _record_access(populated_db, [{"id": "access_test_entry2"}], "q")

        counts = _get_access_counts(
            populated_db, ["access_test_entry1", "access_test_entry2"]
        )
        assert counts["access_test_entry1"] == 5
        assert counts["access_test_entry2"] == 2

    def test_missing_ids_excluded(self, populated_db):
        """IDs not in access log are simply missing from result dict."""
        _record_access(populated_db, [{"id": "access_test_entry1"}], "q")
        counts = _get_access_counts(
            populated_db, ["access_test_entry1", "nonexistent_id"]
        )
        assert "access_test_entry1" in counts
        assert "nonexistent_id" not in counts


# ---------------------------------------------------------------------------
# EDGE-007: Stale entry IDs in access log after reindex
# ---------------------------------------------------------------------------


class TestEdge007OrphanHandling:
    """EDGE-007: Orphan access log entries (for IDs no longer in echo_entries)
    should be cleaned up during reindex."""

    def test_orphan_rows_cleaned_on_reindex(self, db):
        """Access log rows for non-existent entry IDs are deleted on reindex."""
        ensure_schema(db)

        # Insert an access log entry for an ID that does NOT exist
        db.execute(
            "INSERT INTO echo_access_log (entry_id, accessed_at, query) VALUES (?, ?, ?)",
            ("orphan_entry_id", "2026-02-20T00:00:00Z", "test"),
        )
        db.commit()

        # Verify it exists before reindex
        count_before = db.execute(
            "SELECT COUNT(*) FROM echo_access_log WHERE entry_id = 'orphan_entry_id'"
        ).fetchone()[0]
        assert count_before == 1

        # Reindex with a real entry (not the orphan)
        entries = [
            {
                "id": "real_entry_000001",
                "role": "r",
                "layer": "inscribed",
                "date": "2026-02-20",
                "source": "test",
                "content": "real entry content",
                "tags": "real",
                "line_number": 1,
                "file_path": "/p",
            }
        ]
        rebuild_index(db, entries)

        # Orphan should be cleaned up
        count_after = db.execute(
            "SELECT COUNT(*) FROM echo_access_log WHERE entry_id = 'orphan_entry_id'"
        ).fetchone()[0]
        assert count_after == 0

    def test_valid_access_log_preserved_on_reindex(self, db):
        """Access log rows for existing entry IDs survive reindex."""
        entries = [
            {
                "id": "preserved_entry_01",
                "role": "r",
                "layer": "inscribed",
                "date": "2026-02-20",
                "source": "test",
                "content": "preserved content",
                "tags": "preserved",
                "line_number": 1,
                "file_path": "/p",
            }
        ]
        rebuild_index(db, entries)

        # Record accesses
        _record_access(db, [{"id": "preserved_entry_01"}], "q")
        _record_access(db, [{"id": "preserved_entry_01"}], "q")

        count_before = db.execute(
            "SELECT COUNT(*) FROM echo_access_log WHERE entry_id = 'preserved_entry_01'"
        ).fetchone()[0]
        assert count_before == 2

        # Reindex with the same entry
        rebuild_index(db, entries)

        count_after = db.execute(
            "SELECT COUNT(*) FROM echo_access_log WHERE entry_id = 'preserved_entry_01'"
        ).fetchone()[0]
        assert count_after == 2


# ---------------------------------------------------------------------------
# EDGE-010: Bounded growth
# ---------------------------------------------------------------------------


class TestEdge010BoundedGrowth:
    """EDGE-010: Access log should not grow unbounded.
    _record_access prunes when >100k rows.
    rebuild_index prunes entries older than 180 days.
    """

    def _insert_access(self, db, entry_id, query, days_ago=0):
        """Insert an access log entry at a given age."""
        ts = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(time.time() - days_ago * 86400))
        db.execute("INSERT INTO echo_access_log (entry_id, accessed_at, query) VALUES (?, ?, ?)",
                   (entry_id, ts, query))
        db.commit()

    def test_age_based_pruning_on_reindex(self, db):
        """Reindex removes access log entries older than 180 days."""
        entries = [{"id": "age_prune_entry01", "role": "r", "layer": "inscribed",
                    "date": "2026-02-20", "source": "", "content": "content",
                    "tags": "", "line_number": 1, "file_path": "/p"}]
        rebuild_index(db, entries)
        self._insert_access(db, "age_prune_entry01", "old query", days_ago=200)
        self._insert_access(db, "age_prune_entry01", "recent query", days_ago=0)
        assert db.execute("SELECT COUNT(*) FROM echo_access_log").fetchone()[0] == 2
        rebuild_index(db, entries)
        # Old entry pruned, recent preserved
        assert db.execute("SELECT COUNT(*) FROM echo_access_log").fetchone()[0] == 1

    def test_recent_entries_not_pruned(self, db):
        """Recent access log entries survive reindex pruning."""
        entries = [
            {
                "id": "recent_access_entry",
                "role": "r",
                "layer": "inscribed",
                "date": "2026-02-20",
                "source": "",
                "content": "content",
                "tags": "",
                "line_number": 1,
                "file_path": "/p",
            }
        ]
        rebuild_index(db, entries)

        # Record a recent access
        _record_access(db, [{"id": "recent_access_entry"}], "test")

        # Reindex
        rebuild_index(db, entries)

        count = db.execute(
            "SELECT COUNT(*) FROM echo_access_log"
        ).fetchone()[0]
        assert count == 1


# ---------------------------------------------------------------------------
# Frequency scoring with real access data
# ---------------------------------------------------------------------------


class TestFrequencyScoringIntegration:
    """End-to-end frequency scoring with actual access log data."""

    def test_accessed_entry_has_nonzero_frequency(self, populated_db):
        """An entry with recorded accesses should get nonzero frequency score."""
        import math

        # Record 5 accesses for entry 1
        for _ in range(5):
            _record_access(populated_db, [{"id": "access_test_entry1"}], "q")

        counts = _get_access_counts(populated_db, ["access_test_entry1"])
        max_log = math.log(1.0 + counts.get("access_test_entry1", 0))

        score = _score_frequency(
            "access_test_entry1",
            access_counts=counts,
            max_log_count=max_log,
        )
        assert score > 0.0
        assert score == pytest.approx(1.0)  # It's the only entry, so it gets max

    def test_unaccessed_entry_has_zero_frequency(self, populated_db):
        """An entry with no recorded accesses should have frequency=0.0."""
        import math

        # Record accesses only for entry 1
        _record_access(populated_db, [{"id": "access_test_entry1"}], "q")
        counts = _get_access_counts(
            populated_db, ["access_test_entry1", "access_test_entry2"]
        )
        max_log = max(
            (math.log(1.0 + c) for c in counts.values()),
            default=0.0,
        )

        score = _score_frequency(
            "access_test_entry2",
            access_counts=counts,
            max_log_count=max_log,
        )
        assert score == pytest.approx(0.0)

    def test_frequency_ranking_preserves_access_order(self, populated_db):
        """More-accessed entry should get higher frequency score."""
        import math

        for _ in range(10):
            _record_access(populated_db, [{"id": "access_test_entry1"}], "q")
        for _ in range(2):
            _record_access(populated_db, [{"id": "access_test_entry2"}], "q")

        counts = _get_access_counts(
            populated_db, ["access_test_entry1", "access_test_entry2"]
        )
        max_log = max(math.log(1.0 + c) for c in counts.values())

        score1 = _score_frequency(
            "access_test_entry1",
            access_counts=counts,
            max_log_count=max_log,
        )
        score2 = _score_frequency(
            "access_test_entry2",
            access_counts=counts,
            max_log_count=max_log,
        )
        assert score1 > score2
