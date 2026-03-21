"""Tests for server.py — Echo Search MCP Server database helpers."""

import asyncio
import os
import sqlite3
import textwrap
from unittest.mock import AsyncMock, MagicMock, patch

import pytest

# Import the testable, non-MCP functions from server.py.
# The module-level env var validation (ECHO_DIR/DB_PATH) runs on import,
# but defaults to empty strings which pass the forbidden-prefix check.
from server import (
    SCHEMA_VERSION,
    _evidence_basenames,
    _get_echoes_config,
    _load_talisman,
    _migrate_v1,
    _migrate_v2,
    _talisman_cache,
    _tokenize_for_grouping,
    _trace,
    assign_semantic_groups,
    build_fts_query,
    compute_composite_score,
    compute_entry_similarity,
    compute_token_fingerprint,
    ensure_schema,
    expand_semantic_groups,
    get_db,
    get_details,
    get_retry_entries,
    get_stats,
    pipeline_search,
    rebuild_index,
    record_search_failure,
    search_entries,
    upsert_semantic_group,
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
    """Two sample echo entries for testing."""
    return [
        {
            "id": "abc123def4567890",
            "role": "reviewer",
            "layer": "inscribed",
            "date": "2026-01-15",
            "source": "rune:appraise session-1",
            "content": "Always use pre-create guard before TeamCreate",
            "tags": "Team lifecycle guards",
            "line_number": 5,
            "file_path": "/echoes/reviewer/MEMORY.md",
        },
        {
            "id": "1234567890abcdef",
            "role": "orchestrator",
            "layer": "etched",
            "date": "2026-02-01",
            "source": "rune:audit full-scan",
            "content": "Input validation is essential for security hardening",
            "tags": "Security patterns",
            "line_number": 12,
            "file_path": "/echoes/orchestrator/MEMORY.md",
        },
    ]


@pytest.fixture
def populated_db(db, sample_entries):
    """In-memory DB with sample entries indexed."""
    rebuild_index(db, sample_entries)
    return db


# ---------------------------------------------------------------------------
# get_db
# ---------------------------------------------------------------------------

class TestGetDb:
    def test_returns_connection_with_row_factory(self, tmp_path):
        db_path = str(tmp_path / "test.db")
        conn = get_db(db_path)
        try:
            assert conn.row_factory == sqlite3.Row
        finally:
            conn.close()

    def test_wal_mode_enabled(self, tmp_path):
        db_path = str(tmp_path / "test.db")
        conn = get_db(db_path)
        try:
            mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
            assert mode == "wal"
        finally:
            conn.close()


# ---------------------------------------------------------------------------
# ensure_schema
# ---------------------------------------------------------------------------

class TestEnsureSchema:
    def test_creates_tables(self, db):
        tables = {
            row[0]
            for row in db.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        }
        assert "echo_entries" in tables
        assert "echo_meta" in tables
        assert "echo_entries_fts" in tables

    def test_idempotent(self, db):
        """Calling ensure_schema twice should not raise."""
        ensure_schema(db)
        tables = db.execute(
            "SELECT COUNT(*) FROM sqlite_master WHERE type='table'"
        ).fetchone()[0]
        assert tables >= 3  # echo_entries, echo_meta, echo_entries_fts + internal FTS tables

    def test_v2_tables_created(self, db):
        """V2 migration creates semantic_groups and echo_search_failures."""
        tables = {
            row[0]
            for row in db.execute(
                "SELECT name FROM sqlite_master WHERE type='table'"
            ).fetchall()
        }
        assert "semantic_groups" in tables
        assert "echo_search_failures" in tables

    def test_user_version_set(self, db):
        """PRAGMA user_version should be set to SCHEMA_VERSION after ensure_schema."""
        version = db.execute("PRAGMA user_version").fetchone()[0]
        assert version == SCHEMA_VERSION

    def test_v1_to_v2_migration_preserves_data(self):
        """Existing V1 data survives V2 migration without loss."""
        conn = sqlite3.connect(":memory:")
        conn.row_factory = sqlite3.Row
        conn.execute("BEGIN")
        _migrate_v1(conn)
        conn.execute("PRAGMA user_version = 1")
        conn.commit()
        conn.execute(
            """INSERT INTO echo_entries
               (id, role, layer, date, source, content, tags, line_number, file_path)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            ("testentry1234567", "reviewer", "inscribed", "2026-01-01",
             "src", "V1 content", "tags", 1, "/path"),
        )
        conn.commit()
        ensure_schema(conn)
        row = conn.execute(
            "SELECT content FROM echo_entries WHERE id=?", ("testentry1234567",)
        ).fetchone()
        assert row is not None
        assert row[0] == "V1 content"
        assert conn.execute("PRAGMA user_version").fetchone()[0] == SCHEMA_VERSION
        conn.close()

    def test_migration_idempotent_rerun(self):
        """Running ensure_schema on an already-V2 database is a no-op."""
        conn = sqlite3.connect(":memory:")
        conn.row_factory = sqlite3.Row
        ensure_schema(conn)
        conn.execute(
            """INSERT INTO echo_entries
               (id, role, layer, date, source, content, tags, line_number, file_path)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            ("testentry1234567", "r", "inscribed", "", "", "content", "", 1, "/p"),
        )
        conn.execute(
            """INSERT INTO semantic_groups (group_id, entry_id, similarity, created_at)
               VALUES (?, ?, ?, ?)""",
            ("group1234567890a", "testentry1234567", 0.5, "2026-01-01T00:00:00Z"),
        )
        conn.commit()
        ensure_schema(conn)
        assert conn.execute("SELECT COUNT(*) FROM echo_entries").fetchone()[0] == 1
        assert conn.execute("SELECT COUNT(*) FROM semantic_groups").fetchone()[0] == 1
        conn.close()

    def test_v2_cascade_delete(self, db):
        """ON DELETE CASCADE removes group memberships and failures."""
        db.execute(
            """INSERT INTO echo_entries
               (id, role, layer, date, source, content, tags, line_number, file_path)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            ("cascade_test_001", "r", "inscribed", "", "", "c", "", 1, "/p"),
        )
        db.execute(
            """INSERT INTO semantic_groups (group_id, entry_id, similarity, created_at)
               VALUES (?, ?, ?, ?)""",
            ("grp_cascade_0001", "cascade_test_001", 0.5, "2026-01-01T00:00:00Z"),
        )
        db.execute(
            """INSERT INTO echo_search_failures
               (entry_id, token_fingerprint, retry_count, first_failed_at)
               VALUES (?, ?, ?, ?)""",
            ("cascade_test_001", "fp_hash_1234abcd", 0, "2026-01-01T00:00:00Z"),
        )
        db.commit()
        db.execute("DELETE FROM echo_entries WHERE id=?", ("cascade_test_001",))
        db.commit()
        assert db.execute("SELECT COUNT(*) FROM semantic_groups").fetchone()[0] == 0
        assert db.execute("SELECT COUNT(*) FROM echo_search_failures").fetchone()[0] == 0

    def test_foreign_keys_enabled(self, db):
        """FK enforcement is ON after ensure_schema."""
        assert db.execute("PRAGMA foreign_keys").fetchone()[0] == 1

    def test_v2_indexes_created(self, db):
        """V2 migration creates indexes on semantic_groups and echo_search_failures."""
        indexes = {
            row[0]
            for row in db.execute(
                "SELECT name FROM sqlite_master WHERE type='index' AND name LIKE 'idx_%'"
            ).fetchall()
        }
        assert "idx_semantic_groups_entry" in indexes
        assert "idx_semantic_groups_group" in indexes
        assert "idx_search_failures_fingerprint" in indexes
        assert "idx_search_failures_entry" in indexes


# ---------------------------------------------------------------------------
# Semantic grouping (Task 2)
# ---------------------------------------------------------------------------

class TestTokenizeForGrouping:
    def test_basic_tokens(self):
        result = _tokenize_for_grouping("team lifecycle guard pattern")
        assert "team" in result
        assert "lifecycle" in result
        assert "guard" in result
        assert "pattern" in result

    def test_stopwords_removed(self):
        result = _tokenize_for_grouping("the team is for security")
        assert "the" not in result
        assert "is" not in result
        assert "for" not in result
        assert "team" in result
        assert "security" in result

    def test_single_char_removed(self):
        result = _tokenize_for_grouping("a b security")
        assert "a" not in result
        assert "b" not in result
        assert "security" in result

    def test_empty_input(self):
        assert _tokenize_for_grouping("") == set()

    def test_returns_set(self):
        result = _tokenize_for_grouping("error error error")
        assert isinstance(result, set)
        assert result == {"error"}


class TestEvidenceBasenames:
    def test_extracts_backtick_paths(self):
        entry = {"content": "See `src/auth/login.py` for details", "source": "", "file_path": "/p/MEMORY.md"}
        result = _evidence_basenames(entry)
        assert "login.py" in result

    def test_includes_own_file_path(self):
        entry = {"content": "no paths here", "source": "", "file_path": "/echoes/reviewer/MEMORY.md"}
        result = _evidence_basenames(entry)
        assert "memory.md" in result

    def test_empty_content(self):
        entry = {"content": "", "source": "", "file_path": ""}
        result = _evidence_basenames(entry)
        assert isinstance(result, set)


class TestComputeEntrySimilarity:
    def test_identical_entries(self):
        entry = {
            "content": "Authentication security `src/auth.py` pattern",
            "tags": "auth security",
            "source": "",
            "file_path": "/echoes/reviewer/MEMORY.md",
        }
        sim = compute_entry_similarity(entry, entry)
        assert sim == 1.0

    def test_no_overlap(self):
        entry_a = {
            "content": "Authentication `src/auth.py`",
            "tags": "security",
            "source": "",
            "file_path": "/echoes/reviewer/MEMORY.md",
        }
        entry_b = {
            "content": "Database optimization `lib/db.rs`",
            "tags": "performance",
            "source": "",
            "file_path": "/echoes/planner/NOTES.md",
        }
        sim = compute_entry_similarity(entry_a, entry_b)
        assert sim < 0.3  # Below default threshold

    def test_partial_overlap(self):
        entry_a = {
            "content": "Security hardening patterns for `src/auth.py`",
            "tags": "security auth",
            "source": "",
            "file_path": "/echoes/reviewer/MEMORY.md",
        }
        entry_b = {
            "content": "Security validation in `src/auth.py` module",
            "tags": "security validation",
            "source": "",
            "file_path": "/echoes/reviewer/MEMORY.md",
        }
        sim = compute_entry_similarity(entry_a, entry_b)
        assert 0.0 < sim <= 1.0
        assert sim >= 0.3  # Shared "security", "auth.py", "memory.md"

    def test_empty_entries(self):
        entry_a = {"content": "", "tags": "", "source": "", "file_path": ""}
        entry_b = {"content": "", "tags": "", "source": "", "file_path": ""}
        assert compute_entry_similarity(entry_a, entry_b) == 0.0


class TestAssignSemanticGroups:
    def _make_entry(self, entry_id, content, tags="", file_path="/p/MEMORY.md", source=""):
        return {
            "id": entry_id,
            "content": content,
            "tags": tags,
            "source": source,
            "file_path": file_path,
            "role": "r",
            "layer": "inscribed",
            "date": "",
            "line_number": 1,
        }

    def test_groups_similar_entries(self, db):
        entries = [
            self._make_entry("entry_a_12345678", "Security hardening `src/auth.py`", "security auth"),
            self._make_entry("entry_b_12345678", "Security validation `src/auth.py`", "security validation"),
        ]
        rebuild_index(db, entries)
        count = assign_semantic_groups(db, entries, threshold=0.2)
        assert count >= 2
        groups = db.execute("SELECT COUNT(*) FROM semantic_groups").fetchone()[0]
        assert groups >= 2

    def test_no_singleton_groups(self, db):
        """EDGE-008: entries below threshold should not form singleton groups."""
        entries = [
            self._make_entry("entry_a_12345678", "Authentication patterns `src/auth.py`", "auth"),
            self._make_entry("entry_b_12345678", "Database optimization `lib/db.rs`", "database"),
        ]
        rebuild_index(db, entries)
        count = assign_semantic_groups(db, entries, threshold=0.9)
        assert count == 0
        groups = db.execute("SELECT COUNT(*) FROM semantic_groups").fetchone()[0]
        assert groups == 0

    def test_single_entry_no_groups(self, db):
        entries = [self._make_entry("entry_a_12345678", "Sole entry", "solo")]
        rebuild_index(db, entries)
        count = assign_semantic_groups(db, entries)
        assert count == 0

    def test_empty_entries_no_groups(self, db):
        count = assign_semantic_groups(db, [])
        assert count == 0

    def test_threshold_respected(self, db):
        """High threshold should prevent grouping."""
        entries = [
            self._make_entry("entry_a_12345678", "Security topic `src/auth.py`", "sec"),
            self._make_entry("entry_b_12345678", "Security audit `src/auth.py`", "sec"),
        ]
        rebuild_index(db, entries)
        low_count = assign_semantic_groups(db, entries, threshold=0.01)
        db.execute("DELETE FROM semantic_groups")
        db.commit()
        high_count = assign_semantic_groups(db, entries, threshold=0.99)
        assert low_count >= high_count

    def test_max_group_size_splits(self, db):
        """EDGE-009: groups exceeding max size get split."""
        # Create 25 similar entries (all share same file and keyword)
        entries = [
            self._make_entry(
                "entry_%02d_1234567" % i,
                "Security hardening pattern `src/auth.py` number %d" % i,
                "security",
            )
            for i in range(25)
        ]
        rebuild_index(db, entries)
        count = assign_semantic_groups(db, entries, threshold=0.1, max_group_size=10)
        assert count > 0
        # Check no single group has more than 10 members
        groups = db.execute(
            "SELECT group_id, COUNT(*) as cnt FROM semantic_groups GROUP BY group_id"
        ).fetchall()
        for g in groups:
            assert g[1] <= 10

    def test_group_ids_are_hex(self, db):
        """Group IDs should be 16-char hex strings (uuid4)."""
        entries = [
            self._make_entry("entry_a_12345678", "Security `src/auth.py`", "security"),
            self._make_entry("entry_b_12345678", "Security `src/auth.py`", "security"),
        ]
        rebuild_index(db, entries)
        assign_semantic_groups(db, entries, threshold=0.1)
        rows = db.execute("SELECT DISTINCT group_id FROM semantic_groups").fetchall()
        for row in rows:
            gid = row[0]
            assert len(gid) == 16
            assert all(c in "0123456789abcdef" for c in gid)


class TestUpsertSemanticGroup:
    def test_basic_upsert(self, db):
        db.execute(
            """INSERT INTO echo_entries
               (id, role, layer, date, source, content, tags, line_number, file_path)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            ("upsert_test_0001", "r", "inscribed", "", "", "content", "", 1, "/p"),
        )
        db.commit()
        count = upsert_semantic_group(db, "grp_upsert_test_1", ["upsert_test_0001"], [0.5])
        assert count == 1
        row = db.execute(
            "SELECT * FROM semantic_groups WHERE group_id=?", ("grp_upsert_test_1",)
        ).fetchone()
        assert row["entry_id"] == "upsert_test_0001"
        assert abs(row["similarity"] - 0.5) < 0.001

    def test_upsert_replaces(self, db):
        db.execute(
            """INSERT INTO echo_entries
               (id, role, layer, date, source, content, tags, line_number, file_path)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            ("upsert_repl_0001", "r", "inscribed", "", "", "content", "", 1, "/p"),
        )
        db.commit()
        upsert_semantic_group(db, "grp_replace_0001", ["upsert_repl_0001"], [0.3])
        upsert_semantic_group(db, "grp_replace_0001", ["upsert_repl_0001"], [0.8])
        rows = db.execute(
            "SELECT * FROM semantic_groups WHERE group_id=? AND entry_id=?",
            ("grp_replace_0001", "upsert_repl_0001"),
        ).fetchall()
        assert len(rows) == 1
        assert abs(rows[0]["similarity"] - 0.8) < 0.001

    def test_empty_entry_ids(self, db):
        count = upsert_semantic_group(db, "grp_empty_000001", [])
        assert count == 0

    def test_default_similarities(self, db):
        db.execute(
            """INSERT INTO echo_entries
               (id, role, layer, date, source, content, tags, line_number, file_path)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            ("upsert_dfl_00001", "r", "inscribed", "", "", "content", "", 1, "/p"),
        )
        db.commit()
        upsert_semantic_group(db, "grp_default_0001", ["upsert_dfl_00001"])
        row = db.execute(
            "SELECT similarity FROM semantic_groups WHERE entry_id=?", ("upsert_dfl_00001",)
        ).fetchone()
        assert row["similarity"] == 0.0


# ---------------------------------------------------------------------------
# expand_semantic_groups (Task 3)
# ---------------------------------------------------------------------------

# Default weights for testing
_TEST_WEIGHTS = {
    "relevance": 0.30, "importance": 0.30, "recency": 0.20,
    "proximity": 0.10, "frequency": 0.10,
}


class TestExpandSemanticGroups:
    def _make_entry(self, entry_id, content, tags="", layer="inscribed", file_path="/p/MEMORY.md"):
        return {
            "id": entry_id, "content": content, "tags": tags,
            "source": "", "file_path": file_path, "role": "r",
            "layer": layer, "date": "2026-01-01", "line_number": 1,
        }

    def _setup_group(self, db, entries, group_id="grp_test_expand01"):
        """Insert entries and create a group for them."""
        for e in entries:
            db.execute(
                """INSERT OR REPLACE INTO echo_entries
                   (id, role, layer, date, source, content, tags, line_number, file_path)
                   VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)""",
                (e["id"], e["role"], e["layer"], e["date"], e["source"],
                 e["content"], e["tags"], e["line_number"], e["file_path"]),
            )
        db.commit()
        # Rebuild FTS
        rebuild_index(db, entries)
        now = "2026-01-01T00:00:00Z"
        for e in entries:
            db.execute(
                "INSERT OR REPLACE INTO semantic_groups (group_id, entry_id, similarity, created_at) VALUES (?, ?, ?, ?)",
                (group_id, e["id"], 0.5, now),
            )
        db.commit()

    def test_expands_group_members(self, db):
        """Scored results should gain group members."""
        e1 = self._make_entry("expand_a_1234567", "Security auth pattern")
        e2 = self._make_entry("expand_b_1234567", "Security auth helper")
        self._setup_group(db, [e1, e2])

        # Only e1 is in "scored results" — e2 should be expanded
        scored = [{"id": "expand_a_1234567", "source": "", "layer": "inscribed",
                   "role": "r", "date": "2026-01-01", "content_preview": "Security auth pattern",
                   "line_number": 1, "score": -1.0, "composite_score": 0.8}]
        result = expand_semantic_groups(db, scored, _TEST_WEIGHTS)
        ids = [r["id"] for r in result]
        assert "expand_b_1234567" in ids

    def test_discount_applied(self, db):
        """Expanded entries should have discounted composite scores."""
        e1 = self._make_entry("disc_a_123456789", "Security topic")
        e2 = self._make_entry("disc_b_123456789", "Security helper")
        self._setup_group(db, [e1, e2])

        scored = [{"id": "disc_a_123456789", "source": "", "layer": "inscribed",
                   "role": "r", "date": "2026-01-01", "content_preview": "Security topic",
                   "line_number": 1, "score": -1.0, "composite_score": 0.8}]
        result = expand_semantic_groups(db, scored, _TEST_WEIGHTS, discount=0.7)
        expanded = [r for r in result if r.get("expansion_source") == "group_expansion"]
        for entry in expanded:
            # Discount means the composite_score should be lower than original scored entry
            assert entry["composite_score"] < 0.8 or entry["composite_score"] == 0.0

    def test_expansion_source_marked(self, db):
        """Expanded entries should have expansion_source='group_expansion'."""
        e1 = self._make_entry("mark_a_123456789", "Topic A")
        e2 = self._make_entry("mark_b_123456789", "Topic B")
        self._setup_group(db, [e1, e2])

        scored = [{"id": "mark_a_123456789", "source": "", "layer": "inscribed",
                   "role": "r", "date": "2026-01-01", "content_preview": "Topic A",
                   "line_number": 1, "score": -1.0, "composite_score": 0.8}]
        result = expand_semantic_groups(db, scored, _TEST_WEIGHTS)
        expanded = [r for r in result if r["id"] == "mark_b_123456789"]
        assert len(expanded) == 1
        assert expanded[0].get("expansion_source") == "group_expansion"

    def test_no_duplicate_entries(self, db):
        """Entries already in results should not be duplicated (EDGE-010)."""
        e1 = self._make_entry("dedup_a_12345678", "Topic dedup")
        e2 = self._make_entry("dedup_b_12345678", "Topic dedup")
        self._setup_group(db, [e1, e2])

        scored = [
            {"id": "dedup_a_12345678", "source": "", "layer": "inscribed",
             "role": "r", "date": "2026-01-01", "content_preview": "Topic dedup",
             "line_number": 1, "score": -1.0, "composite_score": 0.9},
            {"id": "dedup_b_12345678", "source": "", "layer": "inscribed",
             "role": "r", "date": "2026-01-01", "content_preview": "Topic dedup",
             "line_number": 1, "score": -0.8, "composite_score": 0.7},
        ]
        result = expand_semantic_groups(db, scored, _TEST_WEIGHTS)
        id_counts = {}
        for r in result:
            id_counts[r["id"]] = id_counts.get(r["id"], 0) + 1
        assert all(c == 1 for c in id_counts.values())

    def test_empty_results_passthrough(self, db):
        """Empty input should return empty output."""
        result = expand_semantic_groups(db, [], _TEST_WEIGHTS)
        assert result == []

    def test_no_groups_passthrough(self, db):
        """Results with no group memberships should pass through unchanged."""
        scored = [{"id": "nogroupentry_001", "source": "", "layer": "inscribed",
                   "role": "r", "date": "2026-01-01", "content_preview": "solo",
                   "line_number": 1, "score": -1.0, "composite_score": 0.5}]
        result = expand_semantic_groups(db, scored, _TEST_WEIGHTS)
        assert len(result) == 1
        assert result[0]["id"] == "nogroupentry_001"

    def test_max_expansion_cap(self, db):
        """Max expansion should limit how many entries are added."""
        entries = [self._make_entry("cap_%02d_12345678" % i, "Topic cap %d" % i) for i in range(10)]
        self._setup_group(db, entries)

        scored = [{"id": "cap_00_12345678", "source": "", "layer": "inscribed",
                   "role": "r", "date": "2026-01-01", "content_preview": "Topic cap 0",
                   "line_number": 1, "score": -1.0, "composite_score": 0.9}]
        result = expand_semantic_groups(db, scored, _TEST_WEIGHTS, max_expansion=3)
        # Original 1 + at most 3 expanded
        assert len(result) <= 4


# ---------------------------------------------------------------------------
# rebuild_index
# ---------------------------------------------------------------------------

class TestRebuildIndex:
    def test_inserts_entries(self, db, sample_entries):
        count = rebuild_index(db, sample_entries)
        assert count == 2

        rows = db.execute("SELECT COUNT(*) FROM echo_entries").fetchone()[0]
        assert rows == 2

    def test_replaces_existing_entries(self, db, sample_entries):
        rebuild_index(db, sample_entries)
        rebuild_index(db, sample_entries)
        rows = db.execute("SELECT COUNT(*) FROM echo_entries").fetchone()[0]
        assert rows == 2  # replaced, not duplicated

    def test_clears_old_entries(self, db, sample_entries):
        rebuild_index(db, sample_entries)
        rebuild_index(db, [sample_entries[0]])  # only first entry
        rows = db.execute("SELECT COUNT(*) FROM echo_entries").fetchone()[0]
        assert rows == 1

    def test_empty_entries(self, db):
        count = rebuild_index(db, [])
        assert count == 0

    def test_sets_last_indexed_meta(self, db, sample_entries):
        rebuild_index(db, sample_entries)
        row = db.execute(
            "SELECT value FROM echo_meta WHERE key='last_indexed'"
        ).fetchone()
        assert row is not None
        assert "T" in row[0]  # ISO 8601 format

    def test_rollback_on_error(self, db):
        """If an entry is malformed, transaction rolls back entirely."""
        bad_entries = [
            {
                "id": "goodid1234567890",
                "role": "r",
                "layer": "inscribed",
                "content": "ok",
                "file_path": "/p",
            },
            {
                # Missing required 'id' key → KeyError during execute
                "role": "r",
                "layer": "inscribed",
                "content": "ok",
                "file_path": "/p",
            },
        ]
        with pytest.raises(KeyError):
            rebuild_index(db, bad_entries)

        # Rollback should leave table empty
        count = db.execute("SELECT COUNT(*) FROM echo_entries").fetchone()[0]
        assert count == 0

    def test_unicode_content(self, db):
        """Entries with non-ASCII content are handled correctly."""
        entries = [
            {
                "id": "unicode123456789",
                "role": "reviewer",
                "layer": "inscribed",
                "date": "2026-01-01",
                "source": "rune:appraise",
                "content": "Hệ thống xác thực người dùng 日本語テスト",
                "tags": "unicode test",
                "line_number": 1,
                "file_path": "/p",
            }
        ]
        count = rebuild_index(db, entries)
        assert count == 1

        row = db.execute("SELECT content FROM echo_entries WHERE id=?", ("unicode123456789",)).fetchone()
        assert "Hệ thống" in row[0]

    def test_entry_with_optional_fields_missing(self, db):
        """Entries with missing optional fields use .get() defaults."""
        entries = [
            {
                "id": "minimal123456789",
                "role": "r",
                "layer": "inscribed",
                "content": "minimal entry",
                "file_path": "/p",
                # No date, source, tags, line_number
            }
        ]
        count = rebuild_index(db, entries)
        assert count == 1

        row = db.execute("SELECT date, source, tags, line_number FROM echo_entries WHERE id=?",
                         ("minimal123456789",)).fetchone()
        assert row[0] == ""   # date default
        assert row[1] == ""   # source default
        assert row[2] == ""   # tags default
        assert row[3] == 0    # line_number default

    def test_fts_index_rebuilt_after_reindex(self, db, sample_entries):
        """FTS index stays in sync after multiple rebuilds."""
        rebuild_index(db, sample_entries)
        results_before = search_entries(db, "TeamCreate")
        assert len(results_before) >= 1

        # Rebuild with different content
        new_entries = [
            {
                "id": "newentry123456789",
                "role": "r",
                "layer": "inscribed",
                "date": "",
                "source": "",
                "content": "completely different topic about databases",
                "tags": "databases",
                "line_number": 1,
                "file_path": "/p",
            }
        ]
        rebuild_index(db, new_entries)

        # Old content should no longer be searchable
        results_after = search_entries(db, "TeamCreate")
        assert len(results_after) == 0

        # New content should be searchable
        results_new = search_entries(db, "databases")
        assert len(results_new) == 1

    def test_large_batch_insert(self, db):
        """Rebuild handles 500+ entries without issues."""
        entries = [
            {
                "id": "batch_%04d_padding" % i,
                "role": "r",
                "layer": "inscribed",
                "date": "",
                "source": "",
                "content": "entry number %d content" % i,
                "tags": "batch",
                "line_number": i,
                "file_path": "/p",
            }
            for i in range(500)
        ]
        count = rebuild_index(db, entries)
        assert count == 500

        db_count = db.execute("SELECT COUNT(*) FROM echo_entries").fetchone()[0]
        assert db_count == 500


# ---------------------------------------------------------------------------
# build_fts_query
# ---------------------------------------------------------------------------

class TestBuildFtsQuery:
    def test_basic_query(self):
        result = build_fts_query("team lifecycle guard")
        assert "team" in result
        assert "lifecycle" in result
        assert "guard" in result
        assert " OR " in result

    def test_stopwords_filtered(self):
        result = build_fts_query("the quick brown fox")
        assert "the" not in result.split(" OR ")
        assert "quick" in result
        assert "brown" in result
        assert "fox" in result

    def test_all_stopwords_fallback(self):
        """If all tokens are stopwords, fall back to tokens >= 2 chars."""
        result = build_fts_query("is it the")
        # All are stopwords; fallback keeps those >= 2 chars
        assert "is" in result or "it" in result or "the" in result

    def test_single_char_tokens_dropped(self):
        result = build_fts_query("a b security")
        # "a" and "b" are < 2 chars, "a" is also a stopword
        assert "security" in result

    def test_empty_input(self):
        assert build_fts_query("") == ""

    def test_only_punctuation(self):
        assert build_fts_query("!@#$%^&*()") == ""

    def test_sec7_input_length_cap(self):
        """Inputs longer than 500 chars are truncated before tokenization."""
        long_query = "security " * 100  # 1000 chars
        result = build_fts_query(long_query)
        # Should still produce a valid query, not error
        assert "security" in result

    def test_sec7_token_count_cap(self):
        """No more than 20 tokens in output."""
        many_words = " ".join("word%d" % i for i in range(50))
        result = build_fts_query(many_words)
        tokens = result.split(" OR ")
        assert len(tokens) <= 20

    def test_case_insensitive(self):
        result = build_fts_query("Security HARDENING")
        assert "security" in result
        assert "hardening" in result

    def test_special_chars_stripped(self):
        """FTS5 operators like * and : are not passed through."""
        result = build_fts_query("sec*urity hard:ening")
        # re.findall(r"[a-zA-Z0-9_]+") splits on non-word chars
        assert "*" not in result
        assert ":" not in result

    def test_underscore_preserved(self):
        """Underscores are valid in the token regex [a-zA-Z0-9_]+."""
        result = build_fts_query("pre_create_guard")
        assert "pre_create_guard" in result

    def test_numbers_preserved(self):
        """Numeric tokens are kept."""
        result = build_fts_query("version 145 release")
        assert "145" in result
        assert "version" in result

    def test_mixed_stopwords_and_content(self):
        """Stopwords filtered but content words preserved."""
        result = build_fts_query("the security of the system")
        tokens = result.split(" OR ")
        assert "security" in tokens
        assert "system" in tokens
        assert "the" not in tokens
        assert "of" not in tokens

    def test_duplicate_tokens_preserved(self):
        """Duplicate tokens are kept (FTS5 handles dedup internally)."""
        result = build_fts_query("error error error handling")
        tokens = result.split(" OR ")
        assert tokens.count("error") == 3

    def test_exactly_500_char_input(self):
        """Input exactly at the 500-char boundary."""
        query = "a" * 500
        result = build_fts_query(query)
        # "a" is < 2 chars so it gets dropped, but no truncation error
        assert result == "" or isinstance(result, str)

    def test_tab_and_newline_in_input(self):
        """Whitespace variants are handled by the tokenizer."""
        result = build_fts_query("security\thardening\npatterns")
        assert "security" in result
        assert "hardening" in result
        assert "patterns" in result

    def test_single_valid_token(self):
        """A single non-stopword token produces a query without OR."""
        result = build_fts_query("authentication")
        assert result == "authentication"
        assert " OR " not in result

    def test_all_single_char_returns_empty(self):
        """All tokens < 2 chars (after stopword filter) returns empty."""
        result = build_fts_query("x y z")
        # x, y, z are 1-char; not stopwords but < 2 chars
        assert result == ""


# ---------------------------------------------------------------------------
# search_entries
# ---------------------------------------------------------------------------

class TestSearchEntries:
    def test_basic_search(self, populated_db):
        results = search_entries(populated_db, "TeamCreate guard")
        assert len(results) >= 1
        assert results[0]["role"] == "reviewer"

    def test_search_returns_expected_fields(self, populated_db):
        results = search_entries(populated_db, "validation security")
        assert len(results) >= 1
        r = results[0]
        assert "id" in r
        assert "source" in r
        assert "layer" in r
        assert "role" in r
        assert "content_preview" in r
        assert "score" in r
        assert "line_number" in r

    def test_content_preview_truncated(self, db):
        """content_preview is substr(content, 1, 200) — max 200 chars."""
        long_content = "x" * 500
        entries = [
            {
                "id": "longentry12345678",
                "role": "r",
                "layer": "inscribed",
                "date": "",
                "source": "",
                "content": long_content,
                "tags": "searchable_keyword",
                "line_number": 1,
                "file_path": "/p",
            }
        ]
        rebuild_index(db, entries)
        results = search_entries(db, "searchable_keyword")
        assert len(results) == 1
        assert len(results[0]["content_preview"]) <= 200

    def test_filter_by_layer(self, populated_db):
        results = search_entries(populated_db, "security", layer="etched")
        assert all(r["layer"] == "etched" for r in results)

    def test_filter_by_role(self, populated_db):
        results = search_entries(populated_db, "guard", role="reviewer")
        assert all(r["role"] == "reviewer" for r in results)

    def test_limit_respected(self, populated_db):
        results = search_entries(populated_db, "security", limit=1)
        assert len(results) <= 1

    def test_empty_query_returns_empty(self, populated_db):
        results = search_entries(populated_db, "")
        assert results == []

    def test_no_matches(self, populated_db):
        results = search_entries(populated_db, "zzzznonexistent")
        assert results == []

    def test_combined_layer_and_role_filter(self, populated_db):
        """Both layer and role filters applied simultaneously."""
        results = search_entries(populated_db, "security", layer="etched", role="orchestrator")
        assert len(results) >= 1
        assert all(r["layer"] == "etched" and r["role"] == "orchestrator" for r in results)

    def test_filter_excludes_non_matching(self, populated_db):
        """Layer filter should exclude entries from other layers."""
        results = search_entries(populated_db, "guard", layer="etched")
        # "guard" appears in the inscribed entry, not etched
        assert all(r["layer"] == "etched" for r in results)

    def test_limit_zero_returns_empty(self, populated_db):
        """Limit of 0 should return no results."""
        results = search_entries(populated_db, "security", limit=0)
        assert results == []

    def test_score_is_numeric(self, populated_db):
        """BM25 scores should be float values."""
        results = search_entries(populated_db, "security")
        for r in results:
            assert isinstance(r["score"], float)

    def test_search_after_empty_rebuild(self, db):
        """Search on a DB that was rebuilt with no entries returns empty."""
        rebuild_index(db, [])
        results = search_entries(db, "anything")
        assert results == []

    def test_porter_stemming(self, db):
        """FTS5 uses porter stemmer — 'securing' should match 'security'."""
        entries = [
            {
                "id": "stemtest12345678",
                "role": "r",
                "layer": "inscribed",
                "date": "",
                "source": "",
                "content": "securing the application against threats",
                "tags": "",
                "line_number": 1,
                "file_path": "/p",
            }
        ]
        rebuild_index(db, entries)
        # "security" stems to "secur", "securing" also stems to "secur"
        results = search_entries(db, "security")
        assert len(results) >= 1


# ---------------------------------------------------------------------------
# get_details
# ---------------------------------------------------------------------------

class TestGetDetails:
    def test_fetch_by_id(self, populated_db):
        results = get_details(populated_db, ["abc123def4567890"])
        assert len(results) == 1
        assert results[0]["id"] == "abc123def4567890"
        assert results[0]["full_content"] == "Always use pre-create guard before TeamCreate"

    def test_fetch_multiple_ids(self, populated_db):
        results = get_details(populated_db, ["abc123def4567890", "1234567890abcdef"])
        assert len(results) == 2

    def test_nonexistent_id(self, populated_db):
        results = get_details(populated_db, ["does_not_exist_00"])
        assert results == []

    def test_empty_ids(self, populated_db):
        results = get_details(populated_db, [])
        assert results == []

    def test_sec002_cap_at_100(self, populated_db):
        """IDs list is capped at 100 — defense-in-depth."""
        ids = ["id_%d_padded_to_16" % i for i in range(150)]
        results = get_details(populated_db, ids)
        # Should not error; just returns 0 results since none exist
        assert isinstance(results, list)

    def test_non_string_ids_filtered(self, populated_db):
        """Non-string IDs are filtered out by isinstance check."""
        # Intentionally passing wrong types to test runtime defense-in-depth
        mixed_ids = [123, None, "abc123def4567890"]  # type: ignore[list-item]
        results = get_details(populated_db, mixed_ids)
        # Only the valid string ID should be used
        assert len(results) <= 1

    def test_returns_all_fields(self, populated_db):
        results = get_details(populated_db, ["abc123def4567890"])
        assert len(results) == 1
        r = results[0]
        expected_keys = {"id", "source", "layer", "role", "full_content", "date", "tags", "line_number", "file_path"}
        assert set(r.keys()) == expected_keys

    def test_mixed_existing_and_missing_ids(self, populated_db):
        """Returns only entries that exist, ignores missing IDs."""
        results = get_details(populated_db, ["abc123def4567890", "nonexistent_id_00"])
        assert len(results) == 1
        assert results[0]["id"] == "abc123def4567890"

    def test_duplicate_ids_in_request(self, populated_db):
        """Passing the same ID twice returns it once (SQL IN deduplicates)."""
        results = get_details(populated_db, ["abc123def4567890", "abc123def4567890"])
        assert len(results) == 1

    def test_full_content_not_truncated(self, db):
        """get_details returns full content, not the 200-char preview."""
        long_content = "x" * 500
        entries = [
            {
                "id": "fullcontent12345",
                "role": "r",
                "layer": "inscribed",
                "date": "",
                "source": "",
                "content": long_content,
                "tags": "",
                "line_number": 1,
                "file_path": "/p",
            }
        ]
        rebuild_index(db, entries)
        results = get_details(db, ["fullcontent12345"])
        assert len(results) == 1
        assert len(results[0]["full_content"]) == 500


# ---------------------------------------------------------------------------
# get_stats
# ---------------------------------------------------------------------------

class TestGetStats:
    def test_empty_db(self, db):
        stats = get_stats(db)
        assert stats["total_entries"] == 0
        assert stats["by_layer"] == {}
        assert stats["by_role"] == {}
        assert stats["last_indexed"] == ""

    def test_populated_db(self, populated_db):
        stats = get_stats(populated_db)
        assert stats["total_entries"] == 2
        assert stats["by_layer"]["inscribed"] == 1
        assert stats["by_layer"]["etched"] == 1
        assert stats["by_role"]["reviewer"] == 1
        assert stats["by_role"]["orchestrator"] == 1
        assert stats["last_indexed"] != ""


# ---------------------------------------------------------------------------
# do_reindex (integration test)
# ---------------------------------------------------------------------------

class TestDoReindex:
    def test_end_to_end(self, tmp_path):
        """Full reindex: parse MEMORY.md files → build DB → verify."""
        echo_dir = tmp_path / "echoes"
        role_dir = echo_dir / "reviewer"
        role_dir.mkdir(parents=True)
        (role_dir / "MEMORY.md").write_text(textwrap.dedent("""\
            ## Inscribed — Pattern A (2026-01-01)
            **Source**: `src-1`
            Content for pattern A

            ## Etched — Pattern B (2026-01-02)
            **Source**: `src-2`
            Content for pattern B
        """))

        db_path = str(tmp_path / "echo.db")

        # Import do_reindex (it imports indexer internally)
        from server import do_reindex

        result = do_reindex(str(echo_dir), db_path)

        assert result["entries_indexed"] == 2
        assert result["time_ms"] >= 0
        assert "reviewer" in result["roles"]

        # Verify DB content
        conn = get_db(db_path)
        try:
            stats = get_stats(conn)
            assert stats["total_entries"] == 2
            assert stats["by_role"]["reviewer"] == 2
        finally:
            conn.close()

    def test_reindex_empty_dir(self, tmp_path):
        echo_dir = tmp_path / "empty_echoes"
        echo_dir.mkdir()
        db_path = str(tmp_path / "echo.db")

        from server import do_reindex

        result = do_reindex(str(echo_dir), db_path)
        assert result["entries_indexed"] == 0
        assert result["roles"] == []

    def test_reindex_replaces_previous(self, tmp_path):
        """Second reindex should replace, not append."""
        echo_dir = tmp_path / "echoes"
        role_dir = echo_dir / "test"
        role_dir.mkdir(parents=True)
        (role_dir / "MEMORY.md").write_text(
            "## Inscribed — Entry (2026-01-01)\n**Source**: `s`\nContent"
        )

        db_path = str(tmp_path / "echo.db")
        from server import do_reindex

        do_reindex(str(echo_dir), db_path)
        do_reindex(str(echo_dir), db_path)

        conn = get_db(db_path)
        try:
            count = conn.execute("SELECT COUNT(*) FROM echo_entries").fetchone()[0]
            assert count == 1  # not 2
        finally:
            conn.close()


# ---------------------------------------------------------------------------
# FTS search integration
# ---------------------------------------------------------------------------

class TestFtsIntegration:
    """End-to-end FTS5 search tests using BM25 ranking."""

    def test_search_by_content(self, populated_db):
        results = search_entries(populated_db, "pre-create guard TeamCreate")
        assert len(results) >= 1
        assert results[0]["id"] == "abc123def4567890"

    def test_search_by_tags(self, populated_db):
        """FTS5 indexes content, tags, and source — tags should be searchable."""
        results = search_entries(populated_db, "lifecycle guards")
        assert len(results) >= 1
        assert results[0]["tags"] if "tags" in results[0] else True

    def test_search_by_source(self, populated_db):
        results = search_entries(populated_db, "rune:audit full-scan")
        assert len(results) >= 1

    def test_bm25_ranking(self, db):
        """More relevant results should have more negative scores (ASC order)."""
        entries = [
            {
                "id": "a" * 16,
                "role": "r",
                "layer": "inscribed",
                "date": "",
                "source": "",
                "content": "security security security hardening patterns",
                "tags": "security",
                "line_number": 1,
                "file_path": "/p",
            },
            {
                "id": "b" * 16,
                "role": "r",
                "layer": "inscribed",
                "date": "",
                "source": "",
                "content": "some general content about configuration",
                "tags": "config security",
                "line_number": 2,
                "file_path": "/p",
            },
        ]
        rebuild_index(db, entries)
        results = search_entries(db, "security")
        assert len(results) == 2
        # First result should be more relevant (more negative BM25 score)
        assert results[0]["score"] <= results[1]["score"]

    def test_sec2_no_raw_fts_injection(self, populated_db):
        """FTS5 special syntax should not be injectable via search query."""
        # These would cause FTS5 parse errors if passed raw
        dangerous_queries = [
            'content MATCH "test"',
            "* OR 1=1",
            "NEAR(a, b, 5)",
            '"{column:content}"',
            "content:hack",
        ]
        for q in dangerous_queries:
            # Should not raise — build_fts_query sanitizes
            results = search_entries(populated_db, q)
            assert isinstance(results, list)

    def test_sec2_fts5_column_filter_blocked(self, populated_db):
        """FTS5 column filter syntax (col:term) is not injectable."""
        # In raw FTS5, "source:hack" would search only the source column
        results = search_entries(populated_db, "source:rune")
        # Should search for "source" and "rune" as separate tokens, not as column filter
        assert isinstance(results, list)

    def test_sec2_boolean_operators_not_injectable(self, populated_db):
        """FTS5 AND/NOT/OR operators as raw input are treated as plain words."""
        results = search_entries(populated_db, "security NOT validation")
        # "NOT" is a stopword and gets filtered; doesn't become FTS5 operator
        assert isinstance(results, list)

    def test_search_unicode_content(self, db):
        """FTS5 with unicode61 tokenizer handles non-ASCII text."""
        entries = [
            {
                "id": "unicode_search_01",
                "role": "r",
                "layer": "inscribed",
                "date": "",
                "source": "",
                "content": "Xác thực người dùng bằng mật khẩu",
                "tags": "authentication",
                "line_number": 1,
                "file_path": "/p",
            }
        ]
        rebuild_index(db, entries)
        # Search by tag (ASCII) should find it
        results = search_entries(db, "authentication")
        assert len(results) == 1

    def test_reindex_then_search_integrity(self, db):
        """Index, search, reindex with different data, search again."""
        entries_v1 = [
            {
                "id": "v1_entry_12345678",
                "role": "r",
                "layer": "inscribed",
                "date": "",
                "source": "",
                "content": "original content about authentication",
                "tags": "auth",
                "line_number": 1,
                "file_path": "/p",
            }
        ]
        rebuild_index(db, entries_v1)
        assert len(search_entries(db, "authentication")) == 1

        entries_v2 = [
            {
                "id": "v2_entry_12345678",
                "role": "r",
                "layer": "inscribed",
                "date": "",
                "source": "",
                "content": "replacement content about deployment",
                "tags": "deploy",
                "line_number": 1,
                "file_path": "/p",
            }
        ]
        rebuild_index(db, entries_v2)

        # Old term gone, new term searchable
        assert len(search_entries(db, "authentication")) == 0
        assert len(search_entries(db, "deployment")) == 1


# ---------------------------------------------------------------------------
# Dirty signal helpers
# ---------------------------------------------------------------------------

from server import _signal_path, _check_and_clear_dirty


class TestSignalPath:
    """Unit tests for _signal_path derivation."""

    def test_standard_echo_dir(self):
        path = _signal_path("/project/.rune/echoes")
        assert path == os.path.join("/project", "tmp", ".rune-signals", ".echo-dirty")

    def test_trailing_slash_stripped(self):
        path = _signal_path("/project/.rune/echoes/")
        assert path == os.path.join("/project", "tmp", ".rune-signals", ".echo-dirty")

    def test_empty_echo_dir_returns_empty(self):
        assert _signal_path("") == ""

    def test_non_standard_dir_uses_fallback(self):
        """When ECHO_DIR doesn't end with .rune/echoes, walk up two dirs."""
        path = _signal_path("/custom/path/echoes")
        # Fallback: dirname(dirname("/custom/path/echoes")) = "/custom"
        assert path == os.path.join("/custom", "tmp", ".rune-signals", ".echo-dirty")


class TestCheckAndClearDirty:
    """Unit tests for _check_and_clear_dirty."""

    def test_returns_false_when_no_signal(self, tmp_path):
        echo_dir = str(tmp_path / ".claude" / "echoes")
        os.makedirs(echo_dir, exist_ok=True)
        assert _check_and_clear_dirty(echo_dir) is False

    def test_returns_true_and_deletes_signal(self, tmp_path):
        echo_dir = str(tmp_path / ".claude" / "echoes")
        os.makedirs(echo_dir, exist_ok=True)
        signal_dir = tmp_path / "tmp" / ".rune-signals"
        signal_dir.mkdir(parents=True)
        signal_file = signal_dir / ".echo-dirty"
        signal_file.write_text("1")

        assert _check_and_clear_dirty(echo_dir) is True
        assert not signal_file.exists(), "signal file should be deleted after consumption"

    def test_returns_false_after_second_call(self, tmp_path):
        """Signal is consumed on first call — second call returns False."""
        echo_dir = str(tmp_path / ".claude" / "echoes")
        os.makedirs(echo_dir, exist_ok=True)
        signal_dir = tmp_path / "tmp" / ".rune-signals"
        signal_dir.mkdir(parents=True)
        (signal_dir / ".echo-dirty").write_text("1")

        assert _check_and_clear_dirty(echo_dir) is True
        assert _check_and_clear_dirty(echo_dir) is False

    def test_empty_echo_dir_returns_false(self):
        assert _check_and_clear_dirty("") is False


# ---------------------------------------------------------------------------
# _load_talisman (Task 7)
# ---------------------------------------------------------------------------

class TestLoadTalisman:
    """Unit tests for _load_talisman with mtime caching."""

    def setup_method(self):
        """Reset talisman cache before each test."""
        _talisman_cache["mtime"] = 0.0
        _talisman_cache["config"] = {}

    def test_returns_empty_dict_when_no_file(self, tmp_path, monkeypatch):
        monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path / "nonexistent"))
        # Ensure ECHO_DIR does not point to real file
        monkeypatch.setattr("server.ECHO_DIR", "")
        result = _load_talisman()
        assert result == {}

    def test_loads_yaml_config(self, tmp_path, monkeypatch):
        config_dir = tmp_path / ".claude"
        config_dir.mkdir()
        talisman = config_dir / "talisman.yml"
        talisman.write_text("echoes:\n  reranking:\n    enabled: true\n")
        monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(config_dir))
        monkeypatch.setattr("server.ECHO_DIR", "")
        result = _load_talisman()
        assert result.get("echoes", {}).get("reranking", {}).get("enabled") is True

    def test_mtime_cache_hit(self, tmp_path, monkeypatch):
        config_dir = tmp_path / ".claude"
        config_dir.mkdir()
        talisman = config_dir / "talisman.yml"
        talisman.write_text("key: first\n")
        monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(config_dir))
        monkeypatch.setattr("server.ECHO_DIR", "")
        result1 = _load_talisman()
        assert result1.get("key") == "first"
        # Overwrite without changing mtime — cache should return old value
        talisman.write_text("key: second\n")
        # Restore original mtime
        mtime = _talisman_cache["mtime"]
        os.utime(str(talisman), (mtime, mtime))
        result2 = _load_talisman()
        assert result2.get("key") == "first"  # Cached

    def test_returns_empty_dict_without_yaml(self, tmp_path, monkeypatch):
        """When PyYAML import fails, returns empty dict."""
        config_dir = tmp_path / ".claude"
        config_dir.mkdir()
        talisman = config_dir / "talisman.yml"
        talisman.write_text("echoes: {}\n")
        monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(config_dir))
        monkeypatch.setattr("server.ECHO_DIR", "")
        import builtins
        real_import = builtins.__import__
        def mock_import(name, *args, **kwargs):
            if name == "yaml":
                raise ImportError("no yaml")
            return real_import(name, *args, **kwargs)
        with patch("builtins.__import__", side_effect=mock_import):
            result = _load_talisman()
        assert result == {}

    def test_echo_dir_based_path(self, tmp_path, monkeypatch):
        """Finds talisman.yml relative to ECHO_DIR."""
        claude_dir = tmp_path / ".claude"
        echoes_dir = claude_dir / "echoes"
        echoes_dir.mkdir(parents=True)
        talisman = claude_dir / "talisman.yml"
        talisman.write_text("via_echo_dir: true\n")
        monkeypatch.setattr("config.ECHO_DIR", str(echoes_dir))
        monkeypatch.setenv("CLAUDE_CONFIG_DIR", str(tmp_path / "elsewhere"))
        result = _load_talisman()
        assert result.get("via_echo_dir") is True


# ---------------------------------------------------------------------------
# _get_echoes_config (Task 7)
# ---------------------------------------------------------------------------

class TestGetEchoesConfig:
    """Unit tests for _get_echoes_config nested extraction."""

    def test_extracts_section(self):
        talisman = {"echoes": {"reranking": {"enabled": True, "threshold": 25}}}
        result = _get_echoes_config(talisman, "reranking")
        assert result == {"enabled": True, "threshold": 25}

    def test_missing_section_returns_empty(self):
        talisman = {"echoes": {"decomposition": {"enabled": True}}}
        assert _get_echoes_config(talisman, "reranking") == {}

    def test_missing_echoes_key(self):
        assert _get_echoes_config({}, "reranking") == {}

    def test_non_dict_echoes(self):
        assert _get_echoes_config({"echoes": "not-a-dict"}, "reranking") == {}

    def test_non_dict_section(self):
        assert _get_echoes_config({"echoes": {"reranking": True}}, "reranking") == {}


# ---------------------------------------------------------------------------
# _trace (Task 7)
# ---------------------------------------------------------------------------

class TestTrace:
    """Unit tests for _trace stderr instrumentation."""

    def test_no_output_when_disabled(self, capsys, monkeypatch):
        monkeypatch.setattr("config._RUNE_TRACE", False)
        _trace("test_stage", 0.0)
        assert capsys.readouterr().err == ""

    def test_outputs_when_enabled(self, capsys, monkeypatch):
        import time
        monkeypatch.setattr("config._RUNE_TRACE", True)
        start = time.time()
        _trace("test_stage", start)
        output = capsys.readouterr().err
        assert "[echo-search]" in output
        assert "test_stage" in output


# ---------------------------------------------------------------------------
# pipeline_search (Task 7 — EDGE-027: 16 toggle combinations)
# ---------------------------------------------------------------------------

class TestPipelineSearch:
    """Tests for pipeline_search multi-pass retrieval orchestration."""

    @pytest.fixture
    def pipeline_db(self):
        """DB with schema and sample entries for pipeline testing."""
        conn = sqlite3.connect(":memory:")
        conn.row_factory = sqlite3.Row
        ensure_schema(conn)
        _p = "/echoes/orchestrator/MEMORY.md"
        _mk = lambda id, role, layer, date, src, content, tags, ln, fp: {
            "id": id, "role": role, "layer": layer, "date": date,
            "source": src, "content": content, "tags": tags,
            "line_number": ln, "file_path": fp}
        entries = [
            _mk("pipe-entry-001", "orchestrator", "inscribed", "2026-02-20",
                "rune:appraise test", "Guard pattern for team lifecycle management ensures cleanup",
                "lifecycle", 1, _p),
            _mk("pipe-entry-002", "reviewer", "etched", "2026-02-21",
                "rune:audit session", "Security validation must always check inputs at system boundaries",
                "security", 10, "/echoes/reviewer/MEMORY.md"),
            _mk("pipe-entry-003", "orchestrator", "inscribed", "2026-02-22",
                "rune:strive work", "Team lifecycle cleanup prevents zombie processes and stale state",
                "lifecycle cleanup", 5, _p),
        ]
        rebuild_index(conn, entries)
        return conn

    def _run(self, coro):
        """Helper to run async coroutine synchronously."""
        return asyncio.get_event_loop().run_until_complete(coro)

    def _make_talisman(self, decomp=False, groups=False, retry=False, rerank=False):
        """Build a talisman config with toggled features."""
        return {
            "echoes": {
                "decomposition": {"enabled": decomp},
                "semantic_groups": {"expansion_enabled": groups, "discount": 0.7, "max_expansion": 5},
                "retry": {"enabled": retry},
                "reranking": {"enabled": rerank, "threshold": 1, "max_candidates": 40, "timeout": 4},
            }
        }

    # --- EDGE-027: All 16 toggle combinations ---

    @pytest.mark.parametrize("decomp,groups,retry,rerank", [
        (False, False, False, False),
        (True, False, False, False),
        (False, True, False, False),
        (False, False, True, False),
        (False, False, False, True),
        (True, True, False, False),
        (True, False, True, False),
        (True, False, False, True),
        (False, True, True, False),
        (False, True, False, True),
        (False, False, True, True),
        (True, True, True, False),
        (True, True, False, True),
        (True, False, True, True),
        (False, True, True, True),
        (True, True, True, True),
    ])
    def test_toggle_combinations(self, pipeline_db, monkeypatch, decomp, groups, retry, rerank):
        """EDGE-027: pipeline runs without error for all 16 toggle combos."""
        talisman = self._make_talisman(decomp, groups, retry, rerank)
        monkeypatch.setattr("pipeline._load_talisman", lambda: talisman)
        # Mock decompose_query to avoid subprocess
        mock_decompose = AsyncMock(return_value=["lifecycle", "cleanup"])
        mock_merge = MagicMock(side_effect=lambda results: results[0] if results else [])
        # Mock rerank_results to avoid subprocess
        mock_rerank = AsyncMock(side_effect=lambda q, r, c: r)
        with patch.dict("sys.modules", {
            "decomposer": MagicMock(
                decompose_query=mock_decompose,
                merge_results_by_best_score=mock_merge,
            ),
            "reranker": MagicMock(rerank_results=mock_rerank),
        }):
            results = self._run(pipeline_search(
                pipeline_db, "lifecycle cleanup", 10,
            ))
        assert isinstance(results, list)
        # Base BM25 should always find entries
        assert len(results) > 0

    # --- EDGE-028: threshold check after enrichment ---

    def test_reranking_threshold_after_enrichment(self, pipeline_db, monkeypatch):
        """EDGE-028: reranking threshold applies after all enrichment stages."""
        talisman = self._make_talisman(rerank=True)
        # Set high threshold so reranking is skipped
        talisman["echoes"]["reranking"]["threshold"] = 100
        monkeypatch.setattr("pipeline._load_talisman", lambda: talisman)
        mock_rerank = AsyncMock(side_effect=lambda q, r, c: r)
        with patch.dict("sys.modules", {
            "reranker": MagicMock(rerank_results=mock_rerank),
        }):
            results = self._run(pipeline_search(
                pipeline_db, "lifecycle cleanup", 10,
            ))
        # rerank_results still called (threshold check is inside rerank_results)
        assert isinstance(results, list)

    # --- All features disabled: plain BM25 passthrough ---

    def test_all_disabled_bm25_passthrough(self, pipeline_db, monkeypatch):
        """All features disabled returns BM25 results with composite scoring."""
        talisman = self._make_talisman()
        monkeypatch.setattr("pipeline._load_talisman", lambda: talisman)
        results = self._run(pipeline_search(
            pipeline_db, "lifecycle cleanup", 10,
        ))
        assert len(results) > 0
        # Results should have composite_score from Stage 4
        assert all("composite_score" in r for r in results)

    # --- Over-fetch limit ---

    def test_overfetch_limit(self, pipeline_db, monkeypatch):
        """BM25 stage uses limit * 3 candidates (capped at 150)."""
        talisman = self._make_talisman()
        monkeypatch.setattr("pipeline._load_talisman", lambda: talisman)
        original_search = search_entries
        called_with_limit = []

        def tracking_search(conn, query, limit=10, layer=None, role=None, category=None):
            called_with_limit.append(limit)
            return original_search(conn, query, limit, layer, role, category)

        monkeypatch.setattr("pipeline.search_entries", tracking_search)
        self._run(pipeline_search(pipeline_db, "lifecycle", 5))
        assert called_with_limit[0] == 15  # 5 * 3

    def test_overfetch_capped_at_150(self, pipeline_db, monkeypatch):
        """Overfetch limit caps at 150."""
        talisman = self._make_talisman()
        monkeypatch.setattr("pipeline._load_talisman", lambda: talisman)
        original_search = search_entries
        called_with_limit = []

        def tracking_search(conn, query, limit=10, layer=None, role=None, category=None):
            called_with_limit.append(limit)
            return original_search(conn, query, limit, layer, role, category)

        monkeypatch.setattr("pipeline.search_entries", tracking_search)
        self._run(pipeline_search(pipeline_db, "lifecycle", 100))
        assert called_with_limit[0] == 150  # min(100*3, 150) = 150

    # --- Layer/role filtering passes through ---

    def test_layer_role_passthrough(self, pipeline_db, monkeypatch):
        """Layer and role filters are passed to BM25 search."""
        talisman = self._make_talisman()
        monkeypatch.setattr("pipeline._load_talisman", lambda: talisman)
        results = self._run(pipeline_search(
            pipeline_db, "lifecycle", 10, layer="inscribed",
        ))
        assert all(r.get("layer") == "inscribed" for r in results)

    # --- Decomposition fallback on error ---

    def test_decomposition_fallback_on_import_error(self, pipeline_db, monkeypatch):
        """Decomposition falls back to original query when import fails."""
        talisman = self._make_talisman(decomp=True)
        monkeypatch.setattr("pipeline._load_talisman", lambda: talisman)
        # Remove decomposer from sys.modules to force ImportError
        with patch.dict("sys.modules", {"decomposer": None}):
            results = self._run(pipeline_search(
                pipeline_db, "lifecycle cleanup", 10,
            ))
        assert len(results) > 0

    # --- Reranking fallback on error ---

    def test_reranking_fallback_on_import_error(self, pipeline_db, monkeypatch):
        """Reranking falls back to BM25 results when import fails."""
        talisman = self._make_talisman(rerank=True)
        talisman["echoes"]["reranking"]["threshold"] = 1
        monkeypatch.setattr("pipeline._load_talisman", lambda: talisman)
        with patch.dict("sys.modules", {"reranker": None}):
            results = self._run(pipeline_search(
                pipeline_db, "lifecycle cleanup", 10,
            ))
        assert len(results) > 0

    # --- Retry injection with failure data ---

    def test_retry_injection_merges_entries(self, pipeline_db, monkeypatch):
        """Retry stage injects previously-failed entries matching fingerprint."""
        talisman = self._make_talisman(retry=True)
        monkeypatch.setattr("pipeline._load_talisman", lambda: talisman)
        # Record a search failure — entry_id must exist in echo_entries (FK)
        fp = compute_token_fingerprint("lifecycle cleanup")
        if fp:
            record_search_failure(pipeline_db, "pipe-entry-001", fp)
        results = self._run(pipeline_search(
            pipeline_db, "lifecycle cleanup", 10,
        ))
        assert isinstance(results, list)

    # --- Empty query returns empty ---

    def test_empty_query_returns_empty(self, pipeline_db, monkeypatch):
        """Empty query returns empty results."""
        talisman = self._make_talisman()
        monkeypatch.setattr("pipeline._load_talisman", lambda: talisman)
        results = self._run(pipeline_search(
            pipeline_db, "", 10,
        ))
        assert results == []

    # --- Result limit respected ---

    def test_result_limit(self, pipeline_db, monkeypatch):
        """Final results are capped at the requested limit."""
        talisman = self._make_talisman()
        monkeypatch.setattr("pipeline._load_talisman", lambda: talisman)
        results = self._run(pipeline_search(
            pipeline_db, "lifecycle cleanup security", 1,
        ))
        assert len(results) <= 1

    # --- Integration test with real echo data ---

    def test_integration_full_pipeline(self, pipeline_db, monkeypatch):
        """Integration test: all stages enabled with mocked subprocesses."""
        talisman = self._make_talisman(decomp=True, groups=True, retry=True, rerank=True)
        talisman["echoes"]["reranking"]["threshold"] = 1
        monkeypatch.setattr("pipeline._load_talisman", lambda: talisman)

        # Set up semantic groups for group expansion (entry_ids as list)
        upsert_semantic_group(pipeline_db, "grp-001", ["pipe-entry-001", "pipe-entry-003"], [0.8, 0.8])

        # Record a failure for retry injection (entry_id must exist in echo_entries)
        fp = compute_token_fingerprint("lifecycle cleanup")
        if fp:
            record_search_failure(pipeline_db, "pipe-entry-002", fp)

        # Mock async subprocess calls
        mock_decompose = AsyncMock(return_value=["lifecycle management", "cleanup guard"])
        mock_merge = MagicMock(side_effect=lambda results: results[0] if results else [])
        mock_rerank = AsyncMock(side_effect=lambda q, r, c: r)

        with patch.dict("sys.modules", {
            "decomposer": MagicMock(
                decompose_query=mock_decompose,
                merge_results_by_best_score=mock_merge,
            ),
            "reranker": MagicMock(rerank_results=mock_rerank),
        }):
            results = self._run(pipeline_search(
                pipeline_db, "lifecycle cleanup", 10,
            ))

        assert len(results) > 0
        assert all("composite_score" in r for r in results)
        # Verify decomposition was called
        mock_decompose.assert_called_once()
        # Verify reranking was called
        mock_rerank.assert_called_once()

    # --- EDGE-029: Trace instrumentation ---

    def test_trace_gated_behind_env(self, pipeline_db, monkeypatch, capsys):
        """EDGE-029: Trace output only when _RUNE_TRACE is True."""
        talisman = self._make_talisman()
        monkeypatch.setattr("pipeline._load_talisman", lambda: talisman)
        monkeypatch.setattr("pipeline._RUNE_TRACE", False)
        monkeypatch.setattr("config._RUNE_TRACE", False)
        self._run(pipeline_search(pipeline_db, "lifecycle", 5))
        assert capsys.readouterr().err == ""

    def test_trace_output_when_enabled(self, pipeline_db, monkeypatch, capsys):
        """EDGE-029: Trace output appears when _RUNE_TRACE is True."""
        talisman = self._make_talisman()
        monkeypatch.setattr("pipeline._load_talisman", lambda: talisman)
        monkeypatch.setattr("pipeline._RUNE_TRACE", True)
        monkeypatch.setattr("config._RUNE_TRACE", True)
        self._run(pipeline_search(pipeline_db, "lifecycle", 5))
        err = capsys.readouterr().err
        assert "[echo-search]" in err
        assert "bm25_search" in err
        assert "pipeline_total" in err
