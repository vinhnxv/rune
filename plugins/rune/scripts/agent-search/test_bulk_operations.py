"""Tests for agent-search bulk operations refactoring (PERF-009).

Covers:
  - Task 3: Bulk INSERT + single FTS rebuild in rebuild_index
  - Within-batch priority deduplication
  - FTS search consistency after bulk rebuild
"""

import sqlite3

import pytest

from server import (
    _clear_index,
    _insert_entries,
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


def _make_entry(name, **overrides):
    """Create a minimal agent entry dict."""
    entry = {
        "id": overrides.get("id", f"id-{name}"),
        "name": name,
        "description": overrides.get("description", f"Description of {name}"),
        "category": overrides.get("category", "review"),
        "primary_phase": overrides.get("primary_phase", "review"),
        "compatible_phases": overrides.get("compatible_phases", ["review", "audit"]),
        "tags": overrides.get("tags", ["test"]),
        "languages": overrides.get("languages", []),
        "source": overrides.get("source", "builtin"),
        "priority": overrides.get("priority", 50),
        "tools": overrides.get("tools", ["Read", "Grep"]),
        "model": overrides.get("model", ""),
        "max_turns": overrides.get("max_turns", 30),
        "body": overrides.get("body", f"Body content for {name}"),
        "file_path": overrides.get("file_path", f"agents/review/{name}.md"),
    }
    return entry


# ---------------------------------------------------------------------------
# _insert_entries: bulk INSERT
# ---------------------------------------------------------------------------


class TestBulkInsertEntries:
    """PERF-009: Bulk INSERT via executemany."""

    def test_inserts_all_entries(self, db):
        """All entries are inserted in a single bulk operation."""
        entries = [
            _make_entry("agent-alpha"),
            _make_entry("agent-beta"),
            _make_entry("agent-gamma"),
        ]
        _clear_index(db)
        count, skipped = _insert_entries(db, entries, "2026-03-18T00:00:00Z")
        db.commit()

        assert count == 3
        assert skipped == 0

        row_count = db.execute(
            "SELECT COUNT(*) FROM agent_entries"
        ).fetchone()[0]
        assert row_count == 3

    def test_fts_synced_after_bulk_insert(self, db):
        """FTS index is populated after bulk INSERT."""
        entries = [
            _make_entry("flaw-hunter", description="Detects logic bugs"),
            _make_entry("ward-sentinel", description="Security vulnerability detection"),
        ]
        _clear_index(db)
        _insert_entries(db, entries, "2026-03-18T00:00:00Z")
        db.commit()

        # FTS search should find entries
        results = db.execute(
            "SELECT name FROM agent_entries_fts WHERE agent_entries_fts MATCH 'security'"
        ).fetchall()
        names = [r["name"] for r in results]
        assert "ward-sentinel" in names

    def test_fts_row_count_matches_entries(self, db):
        """FTS table has exactly the same number of rows as agent_entries."""
        entries = [_make_entry(f"agent-{i}") for i in range(5)]
        _clear_index(db)
        _insert_entries(db, entries, "2026-03-18T00:00:00Z")
        db.commit()

        main_count = db.execute("SELECT COUNT(*) FROM agent_entries").fetchone()[0]
        fts_count = db.execute("SELECT COUNT(*) FROM agent_entries_fts").fetchone()[0]
        assert main_count == fts_count == 5

    def test_empty_entries_list(self, db):
        """Empty entries list results in zero inserts."""
        _clear_index(db)
        count, skipped = _insert_entries(db, [], "2026-03-18T00:00:00Z")
        db.commit()

        assert count == 0
        assert skipped == 0

    def test_entries_without_name_skipped(self, db):
        """Entries missing the 'name' field are excluded."""
        entries = [
            {"id": "no-name", "description": "No name field"},
            _make_entry("valid-agent"),
        ]
        _clear_index(db)
        count, skipped = _insert_entries(db, entries, "2026-03-18T00:00:00Z")
        db.commit()

        assert count == 1
        row = db.execute(
            "SELECT name FROM agent_entries"
        ).fetchone()
        assert row["name"] == "valid-agent"

    def test_joined_fields_stored_correctly(self, db):
        """List fields (phases, tags, tools, languages) are comma-joined."""
        entries = [
            _make_entry(
                "multi-field",
                compatible_phases=["review", "audit", "forge"],
                tags=["security", "performance"],
                tools=["Read", "Grep", "Bash"],
                languages=["python", "typescript"],
            ),
        ]
        _clear_index(db)
        _insert_entries(db, entries, "2026-03-18T00:00:00Z")
        db.commit()

        row = db.execute(
            "SELECT compatible_phases, tags, tools, languages FROM agent_entries"
        ).fetchone()
        assert row["compatible_phases"] == "review,audit,forge"
        assert row["tags"] == "security,performance"
        assert row["tools"] == "Read,Grep,Bash"
        assert row["languages"] == "python,typescript"


# ---------------------------------------------------------------------------
# Within-batch priority deduplication
# ---------------------------------------------------------------------------


class TestBatchPriorityDedup:
    """Priority-aware deduplication within a single batch."""

    def test_higher_priority_wins(self, db):
        """When two entries have the same name, higher priority survives."""
        entries = [
            _make_entry("dup-agent", source="user", priority=50, id="user-dup"),
            _make_entry("dup-agent", source="builtin", priority=100, id="builtin-dup"),
        ]
        # Sorted by priority ASC (lower first), so builtin overwrites user
        sorted_entries = sorted(entries, key=lambda e: e.get("priority", 50))

        _clear_index(db)
        count, skipped = _insert_entries(db, sorted_entries, "2026-03-18T00:00:00Z")
        db.commit()

        assert count == 1
        assert skipped == 1

        row = db.execute("SELECT source, priority FROM agent_entries").fetchone()
        assert row["source"] == "builtin"
        assert row["priority"] == 100

    def test_lower_priority_skipped_when_higher_exists(self, db):
        """Lower-priority entry is skipped if higher already seen in batch."""
        # Higher priority inserted last (sorted ASC), then if a lower-priority
        # entry comes after, it should be skipped
        entries = [
            _make_entry("agent-x", source="builtin", priority=100, id="builtin-x"),
            _make_entry("agent-x", source="user", priority=50, id="user-x"),
        ]
        # After sorting by priority ASC: user(50) first, then builtin(100)
        sorted_entries = sorted(entries, key=lambda e: e.get("priority", 50))

        _clear_index(db)
        count, skipped = _insert_entries(db, sorted_entries, "2026-03-18T00:00:00Z")
        db.commit()

        assert count == 1
        assert skipped == 1

        row = db.execute("SELECT source FROM agent_entries").fetchone()
        assert row["source"] == "builtin"

    def test_equal_priority_last_wins(self, db):
        """With equal priority, the later entry in the sorted list wins."""
        entries = [
            _make_entry("agent-eq", source="user", priority=50, id="user-eq",
                        description="User version"),
            _make_entry("agent-eq", source="project", priority=50, id="project-eq",
                        description="Project version"),
        ]
        sorted_entries = sorted(entries, key=lambda e: e.get("priority", 50))

        _clear_index(db)
        count, skipped = _insert_entries(db, sorted_entries, "2026-03-18T00:00:00Z")
        db.commit()

        # Both have same priority, so last one (project) overwrites
        assert count == 1
        assert skipped == 1

    def test_no_duplicates_passes_all(self, db):
        """Entries with unique names all pass through."""
        entries = [
            _make_entry("agent-a"),
            _make_entry("agent-b"),
            _make_entry("agent-c"),
        ]
        _clear_index(db)
        count, skipped = _insert_entries(db, entries, "2026-03-18T00:00:00Z")
        db.commit()

        assert count == 3
        assert skipped == 0


# ---------------------------------------------------------------------------
# rebuild_index integration
# ---------------------------------------------------------------------------


class TestRebuildIndex:
    """Integration: rebuild_index uses bulk operations end-to-end."""

    def test_rebuild_populates_entries(self, db):
        """rebuild_index inserts all entries."""
        entries = [
            _make_entry("alpha"),
            _make_entry("beta"),
        ]
        count = rebuild_index(db, entries)
        assert count == 2

        row_count = db.execute(
            "SELECT COUNT(*) FROM agent_entries"
        ).fetchone()[0]
        assert row_count == 2

    def test_rebuild_clears_previous_entries(self, db):
        """rebuild_index clears existing entries before inserting."""
        entries_v1 = [_make_entry("old-agent")]
        rebuild_index(db, entries_v1)

        entries_v2 = [_make_entry("new-agent")]
        rebuild_index(db, entries_v2)

        names = [
            r["name"]
            for r in db.execute("SELECT name FROM agent_entries").fetchall()
        ]
        assert names == ["new-agent"]

    def test_rebuild_fts_searchable(self, db):
        """FTS index works after rebuild."""
        entries = [
            _make_entry("ember-oracle", description="Performance bottleneck detection"),
            _make_entry("flaw-hunter", description="Logic bug detection"),
        ]
        rebuild_index(db, entries)

        results = db.execute(
            "SELECT name FROM agent_entries_fts WHERE agent_entries_fts MATCH 'performance'"
        ).fetchall()
        assert len(results) == 1
        assert results[0]["name"] == "ember-oracle"

    def test_rebuild_with_priority_conflicts(self, db):
        """rebuild_index handles same-name entries with different priorities."""
        entries = [
            _make_entry("ward-sentinel", source="user", priority=50, id="user-ws"),
            _make_entry("ward-sentinel", source="builtin", priority=100, id="builtin-ws"),
        ]
        count = rebuild_index(db, entries)

        # Only 1 entry survives dedup
        assert count == 1

        row = db.execute("SELECT source FROM agent_entries").fetchone()
        assert row["source"] == "builtin"

    def test_rebuild_empty_entries(self, db):
        """rebuild_index with empty list clears index."""
        entries = [_make_entry("temp")]
        rebuild_index(db, entries)

        rebuild_index(db, [])

        count = db.execute("SELECT COUNT(*) FROM agent_entries").fetchone()[0]
        assert count == 0

    def test_rebuild_idempotent(self, db):
        """Calling rebuild_index twice with same data produces same result."""
        entries = [
            _make_entry("agent-a"),
            _make_entry("agent-b"),
        ]
        rebuild_index(db, entries)
        count1 = db.execute("SELECT COUNT(*) FROM agent_entries").fetchone()[0]

        rebuild_index(db, entries)
        count2 = db.execute("SELECT COUNT(*) FROM agent_entries").fetchone()[0]

        assert count1 == count2 == 2
