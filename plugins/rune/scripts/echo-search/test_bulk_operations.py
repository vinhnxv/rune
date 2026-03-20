"""Tests for SQLite bulk operations refactoring (PERF-002 through PERF-005).

Covers:
  - Task 1: SQL temp table backup/restore for semantic groups (PERF-002, PERF-003)
  - Task 2: Batch access recording via executemany (PERF-004, PERF-005)
"""

import sqlite3

import pytest

from server import (
    _backup_semantic_groups_to_temp,
    _record_access,
    _restore_semantic_groups_from_temp,
    ensure_schema,
    rebuild_index,
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
    """Sample entries for bulk operation tests."""
    return [
        {
            "id": "bulk_entry1",
            "role": "reviewer",
            "layer": "inscribed",
            "date": "2026-03-18",
            "source": "test",
            "content": "First entry for bulk operation tests",
            "tags": "bulk test",
            "line_number": 1,
            "file_path": "/echoes/reviewer/MEMORY.md",
        },
        {
            "id": "bulk_entry2",
            "role": "orchestrator",
            "layer": "etched",
            "date": "2026-03-17",
            "source": "test",
            "content": "Second entry for bulk operation tests",
            "tags": "bulk test",
            "line_number": 2,
            "file_path": "/echoes/orchestrator/MEMORY.md",
        },
        {
            "id": "bulk_entry3",
            "role": "worker",
            "layer": "traced",
            "date": "2026-03-16",
            "source": "test",
            "content": "Third entry for bulk operation tests",
            "tags": "bulk test",
            "line_number": 3,
            "file_path": "/echoes/worker/MEMORY.md",
        },
    ]


@pytest.fixture
def populated_db(db, sample_entries):
    """Database with sample entries indexed."""
    rebuild_index(db, sample_entries)
    return db


# ---------------------------------------------------------------------------
# Task 1: SQL temp table backup/restore (PERF-002, PERF-003)
# ---------------------------------------------------------------------------


class TestBackupSemanticGroupsToTemp:
    """PERF-002: Backup semantic groups using SQL temp table instead of Python."""

    def test_backup_creates_temp_table(self, populated_db):
        """_backup_semantic_groups_to_temp creates a temp table."""
        result = _backup_semantic_groups_to_temp(populated_db)
        assert result is True

        # Verify temp table exists (SQLite temp tables in sqlite_temp_master)
        row = populated_db.execute(
            "SELECT COUNT(*) FROM _sg_backup"
        ).fetchone()
        assert row[0] >= 0  # table exists and is queryable

    def test_backup_copies_all_rows(self, populated_db):
        """Temp table contains all semantic group rows."""
        # Insert some semantic groups
        populated_db.execute(
            "INSERT INTO semantic_groups (group_id, entry_id, similarity, created_at) "
            "VALUES (?, ?, ?, ?)",
            ("g1", "bulk_entry1", 0.9, "2026-03-18T00:00:00Z"),
        )
        populated_db.execute(
            "INSERT INTO semantic_groups (group_id, entry_id, similarity, created_at) "
            "VALUES (?, ?, ?, ?)",
            ("g1", "bulk_entry2", 0.85, "2026-03-18T00:00:00Z"),
        )
        populated_db.commit()

        _backup_semantic_groups_to_temp(populated_db)

        count = populated_db.execute(
            "SELECT COUNT(*) FROM _sg_backup"
        ).fetchone()[0]
        assert count == 2

    def test_backup_returns_false_on_missing_table(self, db):
        """Returns False when semantic_groups table doesn't exist (pre-V2)."""
        # Drop the semantic_groups table to simulate pre-V2 schema
        db.execute("DROP TABLE IF EXISTS semantic_groups")
        result = _backup_semantic_groups_to_temp(db)
        assert result is False

    def test_backup_replaces_previous_temp_table(self, populated_db):
        """Calling backup twice replaces the previous temp table."""
        populated_db.execute(
            "INSERT INTO semantic_groups (group_id, entry_id, similarity, created_at) "
            "VALUES (?, ?, ?, ?)",
            ("g1", "bulk_entry1", 0.9, "2026-03-18T00:00:00Z"),
        )
        populated_db.commit()

        _backup_semantic_groups_to_temp(populated_db)
        count1 = populated_db.execute("SELECT COUNT(*) FROM _sg_backup").fetchone()[0]
        assert count1 == 1

        # Add another group and backup again
        populated_db.execute(
            "INSERT INTO semantic_groups (group_id, entry_id, similarity, created_at) "
            "VALUES (?, ?, ?, ?)",
            ("g1", "bulk_entry2", 0.8, "2026-03-18T00:00:00Z"),
        )
        populated_db.commit()

        _backup_semantic_groups_to_temp(populated_db)
        count2 = populated_db.execute("SELECT COUNT(*) FROM _sg_backup").fetchone()[0]
        assert count2 == 2


class TestRestoreSemanticGroupsFromTemp:
    """PERF-003: Restore semantic groups from SQL temp table."""

    def test_restore_filters_by_existing_entries(self, db, sample_entries):
        """Only restores groups whose entry_id still exists in echo_entries."""
        # Index all 3 entries first
        rebuild_index(db, sample_entries)

        # Create groups for entry1 and entry2
        db.execute(
            "INSERT INTO semantic_groups (group_id, entry_id, similarity, created_at) "
            "VALUES (?, ?, ?, ?)",
            ("g1", "bulk_entry1", 0.9, "2026-03-18T00:00:00Z"),
        )
        db.execute(
            "INSERT INTO semantic_groups (group_id, entry_id, similarity, created_at) "
            "VALUES (?, ?, ?, ?)",
            ("g1", "bulk_entry2", 0.85, "2026-03-18T00:00:00Z"),
        )
        db.execute(
            "INSERT INTO semantic_groups (group_id, entry_id, similarity, created_at) "
            "VALUES (?, ?, ?, ?)",
            ("g2", "bulk_entry2", 0.7, "2026-03-18T00:00:00Z"),
        )
        db.execute(
            "INSERT INTO semantic_groups (group_id, entry_id, similarity, created_at) "
            "VALUES (?, ?, ?, ?)",
            ("g2", "bulk_entry3", 0.7, "2026-03-18T00:00:00Z"),
        )
        db.commit()

        _backup_semantic_groups_to_temp(db)

        # Clear groups, then rebuild with only entry1 (entry2 and entry3 removed)
        db.execute("DELETE FROM semantic_groups")
        db.execute("DELETE FROM echo_entries")
        db.execute("DELETE FROM echo_entries_fts")
        # Re-insert only entry1
        from server import _insert_entries
        _insert_entries(db, [sample_entries[0]])
        db.commit()

        restored = _restore_semantic_groups_from_temp(db)
        # g1 had entry1+entry2, only entry1 survives → degenerate (1 member) → cleaned
        # g2 had entry2+entry3, neither survives → 0 restored for g2
        # So restored count from INSERT is 1 (entry1 in g1), but degenerate cleanup removes it
        remaining = db.execute(
            "SELECT COUNT(*) FROM semantic_groups"
        ).fetchone()[0]
        assert remaining == 0  # all groups degenerate after filtering

    def test_restore_cleans_degenerate_groups(self, populated_db):
        """Groups with fewer than 2 members are cleaned up after restore."""
        # Create a group with only 1 member
        populated_db.execute(
            "INSERT INTO semantic_groups (group_id, entry_id, similarity, created_at) "
            "VALUES (?, ?, ?, ?)",
            ("lonely_group", "bulk_entry1", 0.9, "2026-03-18T00:00:00Z"),
        )
        populated_db.commit()

        _backup_semantic_groups_to_temp(populated_db)
        populated_db.execute("DELETE FROM semantic_groups")
        populated_db.commit()

        _restore_semantic_groups_from_temp(populated_db)

        count = populated_db.execute(
            "SELECT COUNT(*) FROM semantic_groups WHERE group_id = 'lonely_group'"
        ).fetchone()[0]
        assert count == 0  # degenerate group cleaned up

    def test_restore_drops_temp_table(self, populated_db):
        """Temp table is dropped after restore."""
        _backup_semantic_groups_to_temp(populated_db)
        _restore_semantic_groups_from_temp(populated_db)

        with pytest.raises(sqlite3.OperationalError):
            populated_db.execute("SELECT COUNT(*) FROM _sg_backup")

    def test_restore_without_backup_returns_zero(self, populated_db):
        """Calling restore without a backup table returns 0."""
        result = _restore_semantic_groups_from_temp(populated_db)
        assert result == 0

    def test_restore_preserves_similarity_values(self, populated_db):
        """Restored groups retain their original similarity scores."""
        populated_db.execute(
            "INSERT INTO semantic_groups (group_id, entry_id, similarity, created_at) "
            "VALUES (?, ?, ?, ?)",
            ("g1", "bulk_entry1", 0.95, "2026-03-18T00:00:00Z"),
        )
        populated_db.execute(
            "INSERT INTO semantic_groups (group_id, entry_id, similarity, created_at) "
            "VALUES (?, ?, ?, ?)",
            ("g1", "bulk_entry2", 0.87, "2026-03-18T00:00:00Z"),
        )
        populated_db.commit()

        _backup_semantic_groups_to_temp(populated_db)
        populated_db.execute("DELETE FROM semantic_groups")
        populated_db.commit()

        _restore_semantic_groups_from_temp(populated_db)

        rows = populated_db.execute(
            "SELECT entry_id, similarity FROM semantic_groups ORDER BY entry_id"
        ).fetchall()
        assert len(rows) == 2
        sims = {r["entry_id"]: r["similarity"] for r in rows}
        assert abs(sims["bulk_entry1"] - 0.95) < 1e-9
        assert abs(sims["bulk_entry2"] - 0.87) < 1e-9


class TestRebuildIndexPreservesGroups:
    """Integration: rebuild_index uses temp table approach end-to-end."""

    def test_rebuild_preserves_valid_groups(self, db, sample_entries):
        """Groups referencing valid entries survive rebuild_index."""
        rebuild_index(db, sample_entries)

        # Add a semantic group
        db.execute(
            "INSERT INTO semantic_groups (group_id, entry_id, similarity, created_at) "
            "VALUES (?, ?, ?, ?)",
            ("g1", "bulk_entry1", 0.9, "2026-03-18T00:00:00Z"),
        )
        db.execute(
            "INSERT INTO semantic_groups (group_id, entry_id, similarity, created_at) "
            "VALUES (?, ?, ?, ?)",
            ("g1", "bulk_entry2", 0.85, "2026-03-18T00:00:00Z"),
        )
        db.commit()

        # Rebuild with same entries
        rebuild_index(db, sample_entries)

        count = db.execute(
            "SELECT COUNT(*) FROM semantic_groups WHERE group_id = 'g1'"
        ).fetchone()[0]
        assert count == 2

    def test_rebuild_drops_groups_for_removed_entries(self, db, sample_entries):
        """Groups referencing removed entries are not restored after rebuild."""
        rebuild_index(db, sample_entries)

        db.execute(
            "INSERT INTO semantic_groups (group_id, entry_id, similarity, created_at) "
            "VALUES (?, ?, ?, ?)",
            ("g1", "bulk_entry1", 0.9, "2026-03-18T00:00:00Z"),
        )
        db.execute(
            "INSERT INTO semantic_groups (group_id, entry_id, similarity, created_at) "
            "VALUES (?, ?, ?, ?)",
            ("g1", "bulk_entry2", 0.85, "2026-03-18T00:00:00Z"),
        )
        db.commit()

        # Rebuild with only entry1 — entry2 is removed
        rebuild_index(db, [sample_entries[0]])

        # Group g1 should be cleaned as degenerate (only 1 member left)
        count = db.execute(
            "SELECT COUNT(*) FROM semantic_groups"
        ).fetchone()[0]
        assert count == 0


# ---------------------------------------------------------------------------
# Task 2: Batch access recording (PERF-004, PERF-005)
# ---------------------------------------------------------------------------


class TestBatchAccessRecording:
    """PERF-004: Access recording uses executemany for batch INSERT."""

    def test_batch_inserts_all_entries(self, populated_db):
        """All result entry IDs are recorded in a single batch."""
        results = [
            {"id": "bulk_entry1"},
            {"id": "bulk_entry2"},
            {"id": "bulk_entry3"},
        ]
        _record_access(populated_db, results, "test query")

        count = populated_db.execute(
            "SELECT COUNT(*) FROM echo_access_log"
        ).fetchone()[0]
        assert count == 3

    def test_batch_records_same_timestamp(self, populated_db):
        """All entries in a batch share the same timestamp."""
        results = [
            {"id": "bulk_entry1"},
            {"id": "bulk_entry2"},
        ]
        _record_access(populated_db, results, "test")

        timestamps = populated_db.execute(
            "SELECT DISTINCT accessed_at FROM echo_access_log"
        ).fetchall()
        assert len(timestamps) == 1  # all same timestamp

    def test_batch_records_same_query(self, populated_db):
        """All entries in a batch share the same query string."""
        results = [
            {"id": "bulk_entry1"},
            {"id": "bulk_entry2"},
        ]
        _record_access(populated_db, results, "shared query")

        queries = populated_db.execute(
            "SELECT DISTINCT query FROM echo_access_log"
        ).fetchall()
        assert len(queries) == 1
        assert queries[0][0] == "shared query"

    def test_batch_skips_empty_ids(self, populated_db):
        """Entries with empty or missing IDs are excluded from the batch."""
        results = [
            {"id": "bulk_entry1"},
            {"id": ""},
            {"no_id": "value"},
            {"id": "bulk_entry2"},
        ]
        _record_access(populated_db, results, "test")

        count = populated_db.execute(
            "SELECT COUNT(*) FROM echo_access_log"
        ).fetchone()[0]
        assert count == 2

    def test_batch_empty_results_no_op(self, populated_db):
        """Empty results list produces no access log entries."""
        _record_access(populated_db, [], "test")

        count = populated_db.execute(
            "SELECT COUNT(*) FROM echo_access_log"
        ).fetchone()[0]
        assert count == 0

    def test_batch_query_length_capped(self, populated_db):
        """Query string is capped at 500 characters in batch mode."""
        long_query = "x" * 1000
        results = [{"id": "bulk_entry1"}, {"id": "bulk_entry2"}]
        _record_access(populated_db, results, long_query)

        rows = populated_db.execute(
            "SELECT query FROM echo_access_log"
        ).fetchall()
        for row in rows:
            assert len(row["query"]) <= 500


class TestBatchUnarchive:
    """PERF-005: Batch unarchive uses single UPDATE ... WHERE IN."""

    def test_batch_unarchives_accessed_entries(self, populated_db):
        """Archived entries are unarchived when accessed."""
        # Archive entries
        populated_db.execute(
            "UPDATE echo_entries SET archived = 1 WHERE id IN ('bulk_entry1', 'bulk_entry2')"
        )
        populated_db.commit()

        # Verify archived
        archived = populated_db.execute(
            "SELECT COUNT(*) FROM echo_entries WHERE archived = 1"
        ).fetchone()[0]
        assert archived == 2

        # Access both entries in a single batch
        results = [{"id": "bulk_entry1"}, {"id": "bulk_entry2"}]
        _record_access(populated_db, results, "test")

        # Verify unarchived
        archived_after = populated_db.execute(
            "SELECT COUNT(*) FROM echo_entries WHERE archived = 1"
        ).fetchone()[0]
        assert archived_after == 0

    def test_batch_unarchive_only_affects_archived(self, populated_db):
        """Unarchive only changes entries that were actually archived."""
        # Archive only entry1
        populated_db.execute(
            "UPDATE echo_entries SET archived = 1 WHERE id = 'bulk_entry1'"
        )
        populated_db.commit()

        results = [{"id": "bulk_entry1"}, {"id": "bulk_entry2"}]
        _record_access(populated_db, results, "test")

        # entry1 unarchived, entry2 was never archived — both should be 0
        rows = populated_db.execute(
            "SELECT id, archived FROM echo_entries WHERE id IN ('bulk_entry1', 'bulk_entry2')"
        ).fetchall()
        for row in rows:
            assert row["archived"] == 0
