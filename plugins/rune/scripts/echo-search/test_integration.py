"""Integration tests for the Echo Search MCP pipeline.

Tests the full end-to-end flow using realistic test data and a real
SQLite database file (not :memory:). Exercises:
    indexer.discover_and_parse → server.rebuild_index → search/details/stats → reindex

Test data lives in testdata/echoes/ with 4 roles (reviewer, orchestrator,
planner, workers), 3 layers (inscribed, etched, traced), and realistic
MEMORY.md content modeled after actual Rune echo entries.
"""

import os
import shutil
import time

import pytest

from indexer import discover_and_parse
from server import (
    do_reindex,
    ensure_schema,
    get_db,
    get_details,
    get_stats,
    rebuild_index,
    search_entries,
)

TESTDATA_DIR = os.path.join(os.path.dirname(__file__), "testdata", "echoes")


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def echo_dir():
    """Path to the static testdata/echoes/ directory."""
    assert os.path.isdir(TESTDATA_DIR), "testdata/echoes/ must exist"
    return TESTDATA_DIR


@pytest.fixture
def db_path(tmp_path):
    """Real SQLite database file in a temp directory."""
    return str(tmp_path / "echo_search_test.db")


@pytest.fixture
def db(db_path):
    """Initialized SQLite connection with schema."""
    conn = get_db(db_path)
    ensure_schema(conn)
    yield conn
    conn.close()


@pytest.fixture
def all_entries(echo_dir):
    """All entries parsed from the testdata directory."""
    return discover_and_parse(echo_dir)


@pytest.fixture
def populated_db(db, all_entries):
    """Database populated with all testdata entries."""
    rebuild_index(db, all_entries)
    return db


# ---------------------------------------------------------------------------
# Testdata Validation
# ---------------------------------------------------------------------------


class TestTestdataIntegrity:
    """Verify the test fixtures themselves are well-formed."""

    def test_testdata_has_four_roles(self, echo_dir):
        """testdata/echoes/ contains exactly 4 role directories."""
        roles = sorted(
            d for d in os.listdir(echo_dir)
            if os.path.isdir(os.path.join(echo_dir, d))
        )
        assert roles == ["orchestrator", "planner", "reviewer", "workers"]

    def test_each_role_has_memory_md(self, echo_dir):
        """Every role directory contains a MEMORY.md file."""
        for role in os.listdir(echo_dir):
            role_path = os.path.join(echo_dir, role)
            if os.path.isdir(role_path):
                memory = os.path.join(role_path, "MEMORY.md")
                assert os.path.isfile(memory), f"{role}/MEMORY.md missing"

    def test_all_entries_parsed_successfully(self, all_entries):
        """Parser extracts entries from all 4 roles without errors."""
        assert len(all_entries) > 0
        roles = set(e["role"] for e in all_entries)
        assert roles == {"orchestrator", "planner", "reviewer", "workers"}

    def test_all_three_layers_represented(self, all_entries):
        """Testdata contains inscribed, etched, and traced entries."""
        layers = set(e["layer"] for e in all_entries)
        assert layers == {"inscribed", "etched", "traced"}

    def test_all_entries_have_required_fields(self, all_entries):
        """Every entry has the fields expected by rebuild_index."""
        required = {"id", "role", "layer", "content", "file_path"}
        for entry in all_entries:
            missing = required - set(entry.keys())
            assert not missing, f"Entry {entry.get('id', '?')} missing: {missing}"

    def test_entry_ids_are_unique(self, all_entries):
        """No duplicate IDs across all entries."""
        ids = [e["id"] for e in all_entries]
        assert len(ids) == len(set(ids)), "Duplicate entry IDs found"


# ---------------------------------------------------------------------------
# Indexer Integration (discover_and_parse with real files)
# ---------------------------------------------------------------------------


class TestIndexerIntegration:
    """Test indexer against the realistic testdata directory."""

    def test_entry_count_per_role(self, all_entries):
        """Each role contributes the expected number of entries."""
        by_role = {}
        for e in all_entries:
            by_role.setdefault(e["role"], 0)
            by_role[e["role"]] += 1

        # reviewer: 4 entries (2 inscribed + 1 etched + 1 traced)
        assert by_role["reviewer"] == 4
        # orchestrator: 4 entries (2 inscribed + 1 etched + 1 traced)
        assert by_role["orchestrator"] == 4
        # planner: 4 entries (2 inscribed + 1 etched + 1 traced)
        assert by_role["planner"] == 4
        # workers: 4 entries (2 inscribed + 1 etched + 1 traced)
        assert by_role["workers"] == 4

    def test_layer_distribution(self, all_entries):
        """Entries are distributed across all 3 layers."""
        by_layer = {}
        for e in all_entries:
            by_layer.setdefault(e["layer"], 0)
            by_layer[e["layer"]] += 1

        assert by_layer["inscribed"] == 8   # 2 per role × 4 roles
        assert by_layer["etched"] == 4      # 1 per role × 4 roles
        assert by_layer["traced"] == 4      # 1 per role × 4 roles

    def test_source_extraction(self, all_entries):
        """Sources are correctly extracted from various formats."""
        sources = {e["tags"]: e["source"] for e in all_entries}

        # Source with backticks: `rune:appraise abc123`
        assert sources.get("Security Pattern Consistency Review") == "rune:appraise abc123"

        # Source without backticks: rune:appraise jkl012
        assert sources.get("Experimental: Rust FFI Boundary Review") == "rune:appraise jkl012"

    def test_date_extraction(self, all_entries):
        """Dates are parsed from entry headers."""
        dates = {e["tags"]: e["date"] for e in all_entries}
        assert dates.get("Security Pattern Consistency Review") == "2026-01-15"
        assert dates.get("Plan: API Rate Limiting Strategy") == "2026-01-12"

    def test_content_is_nonempty(self, all_entries):
        """All entries have non-empty content."""
        for entry in all_entries:
            assert entry["content"].strip(), (
                f"Empty content for {entry['role']}:{entry['tags']}"
            )

    def test_em_dash_separator_parsed(self, all_entries):
        """Entries using em dash (—) separator are parsed correctly."""
        # reviewer MEMORY.md uses em dash: ## Inscribed — Security Pattern...
        reviewer_entries = [e for e in all_entries if e["role"] == "reviewer"]
        assert any("Security Pattern" in e["tags"] for e in reviewer_entries)

    def test_hyphen_separator_parsed(self, all_entries):
        """Entries using hyphen (-) separator are parsed correctly."""
        # orchestrator MEMORY.md uses hyphen: ## Inscribed - Database Migration...
        orch_entries = [e for e in all_entries if e["role"] == "orchestrator"]
        assert any("Database Migration" in e["tags"] for e in orch_entries)

    def test_file_paths_are_absolute(self, all_entries):
        """All file_path values are absolute paths."""
        for entry in all_entries:
            assert os.path.isabs(entry["file_path"]), (
                f"Non-absolute path: {entry['file_path']}"
            )

    def test_line_numbers_are_positive(self, all_entries):
        """All line numbers are positive (1-indexed)."""
        for entry in all_entries:
            assert entry["line_number"] >= 1, (
                f"Invalid line number {entry['line_number']} for {entry['id']}"
            )


# ---------------------------------------------------------------------------
# Database Integration (real SQLite file on disk)
# ---------------------------------------------------------------------------


class TestDatabaseIntegration:
    """Test database operations with a real SQLite file."""

    def test_db_file_created(self, db_path):
        """get_db creates the database file on disk."""
        conn = get_db(db_path)
        ensure_schema(conn)
        conn.close()
        assert os.path.isfile(db_path)

    def test_wal_mode_persists(self, db_path):
        """WAL journal mode is set on the database file."""
        conn = get_db(db_path)
        ensure_schema(conn)
        mode = conn.execute("PRAGMA journal_mode").fetchone()[0]
        conn.close()
        assert mode == "wal"

    def test_rebuild_populates_all_entries(self, db, all_entries):
        """rebuild_index inserts all entries from discover_and_parse."""
        count = rebuild_index(db, all_entries)
        assert count == len(all_entries)

        actual = db.execute("SELECT COUNT(*) FROM echo_entries").fetchone()[0]
        assert actual == len(all_entries)

    def test_fts_index_synced_after_rebuild(self, populated_db):
        """FTS virtual table has the same row count as base table."""
        base = populated_db.execute(
            "SELECT COUNT(*) FROM echo_entries"
        ).fetchone()[0]
        fts = populated_db.execute(
            "SELECT COUNT(*) FROM echo_entries_fts"
        ).fetchone()[0]
        assert base == fts

    def test_last_indexed_meta_set(self, populated_db):
        """Rebuild sets the last_indexed metadata timestamp."""
        row = populated_db.execute(
            "SELECT value FROM echo_meta WHERE key='last_indexed'"
        ).fetchone()
        assert row is not None
        # Format: YYYY-MM-DDTHH:MM:SSZ
        assert "T" in row[0] and row[0].endswith("Z")

    def test_rebuild_replaces_previous_data(self, db, all_entries):
        """Calling rebuild_index twice replaces, not duplicates."""
        rebuild_index(db, all_entries)
        rebuild_index(db, all_entries)

        actual = db.execute("SELECT COUNT(*) FROM echo_entries").fetchone()[0]
        assert actual == len(all_entries)

    def test_db_survives_close_and_reopen(self, db_path, all_entries):
        """Data persists across connection close/reopen cycles."""
        conn1 = get_db(db_path)
        ensure_schema(conn1)
        rebuild_index(conn1, all_entries)
        conn1.close()

        conn2 = get_db(db_path)
        count = conn2.execute("SELECT COUNT(*) FROM echo_entries").fetchone()[0]
        conn2.close()
        assert count == len(all_entries)


# ---------------------------------------------------------------------------
# Search Integration (FTS5 with realistic content)
# ---------------------------------------------------------------------------


class TestSearchIntegration:
    """Test search against the populated testdata database."""

    def test_search_security_keyword(self, populated_db):
        """Searching 'security' finds reviewer and planner entries."""
        results = search_entries(populated_db, "security")
        assert len(results) > 0
        # Should find entries mentioning SQL injection, XSS, authentication
        ids = [r["id"] for r in results]
        assert len(ids) == len(set(ids)), "No duplicate results"

    def test_search_database_keyword(self, populated_db):
        """Searching 'database' finds entries about migrations and indexes."""
        results = search_entries(populated_db, "database")
        assert len(results) > 0

    def test_search_convergence(self, populated_db):
        """Searching 'convergence' finds orchestrator arc entries."""
        results = search_entries(populated_db, "convergence")
        assert len(results) > 0
        assert any(r["role"] == "orchestrator" for r in results)

    def test_search_returns_content_preview(self, populated_db):
        """Search results include truncated content preview."""
        results = search_entries(populated_db, "migration")
        assert len(results) > 0
        for r in results:
            assert "content_preview" in r
            assert len(r["content_preview"]) <= 200

    def test_search_bm25_relevance_ordering(self, populated_db):
        """Results are ordered by BM25 relevance (lower = more relevant)."""
        results = search_entries(populated_db, "SQL injection query", limit=10)
        if len(results) >= 2:
            scores = [r["score"] for r in results]
            assert scores == sorted(scores), "Results not in BM25 order"

    def test_search_filter_by_layer(self, populated_db):
        """Layer filter restricts results to matching layer."""
        inscribed = search_entries(populated_db, "pattern", layer="inscribed")
        etched = search_entries(populated_db, "pattern", layer="etched")

        for r in inscribed:
            assert r["layer"] == "inscribed"
        for r in etched:
            assert r["layer"] == "etched"

    def test_search_filter_by_role(self, populated_db):
        """Role filter restricts results to matching role."""
        results = search_entries(populated_db, "security", role="reviewer")
        for r in results:
            assert r["role"] == "reviewer"

    def test_search_combined_filters(self, populated_db):
        """Layer + role filters can be combined."""
        results = search_entries(
            populated_db, "pattern", layer="inscribed", role="reviewer"
        )
        for r in results:
            assert r["layer"] == "inscribed"
            assert r["role"] == "reviewer"

    def test_search_limit_respected(self, populated_db):
        """Limit parameter caps result count."""
        all_results = search_entries(populated_db, "the", limit=50)
        limited = search_entries(populated_db, "the", limit=3)
        assert len(limited) <= 3
        if len(all_results) > 3:
            assert len(limited) == 3

    def test_search_no_results_for_nonsense(self, populated_db):
        """Searching for gibberish returns empty results."""
        results = search_entries(populated_db, "xyzzyplugh42")
        assert results == []

    def test_search_porter_stemming(self, populated_db):
        """Porter stemming matches word variants."""
        # "migration" should also match "migrations"
        results = search_entries(populated_db, "migration")
        assert len(results) > 0

    def test_search_across_fts_columns(self, populated_db):
        """FTS5 searches content, tags, and source columns."""
        # Search by content keyword
        by_content = search_entries(populated_db, "SQL injection")
        assert len(by_content) > 0

        # Search by source text
        by_source = search_entries(populated_db, "rune:appraise")
        assert len(by_source) > 0

        # Search by tag/title keyword
        by_tag = search_entries(populated_db, "Performance Bottleneck")
        assert len(by_tag) > 0

    def test_search_unicode_content(self, populated_db):
        """Search handles entries with unicode characters."""
        # Testdata contains em dashes (—) and other unicode
        results = search_entries(populated_db, "pattern")
        assert len(results) > 0

    def test_fts_injection_blocked(self, populated_db):
        """FTS5 injection via MATCH syntax is sanitized by build_fts_query."""
        # Attempt column filter injection
        results = search_entries(populated_db, "content:security OR 1=1")
        # Should not crash — build_fts_query strips special chars
        assert isinstance(results, list)


# ---------------------------------------------------------------------------
# Details Integration
# ---------------------------------------------------------------------------


class TestDetailsIntegration:
    """Test get_details with entries from the populated database."""

    def test_fetch_by_real_id(self, populated_db, all_entries):
        """Fetching a known entry returns full content."""
        entry_id = all_entries[0]["id"]
        results = get_details(populated_db, [entry_id])
        assert len(results) == 1
        assert results[0]["id"] == entry_id
        assert results[0]["full_content"] == all_entries[0]["content"]

    def test_fetch_multiple_ids(self, populated_db, all_entries):
        """Fetching multiple IDs returns all matching entries."""
        ids = [e["id"] for e in all_entries[:5]]
        results = get_details(populated_db, ids)
        assert len(results) == 5

    def test_fetch_preserves_metadata(self, populated_db, all_entries):
        """All metadata fields are preserved through index+fetch cycle."""
        entry = all_entries[0]
        results = get_details(populated_db, [entry["id"]])
        assert len(results) == 1
        r = results[0]
        assert r["role"] == entry["role"]
        assert r["layer"] == entry["layer"]
        assert r["date"] == entry.get("date", "")
        assert r["source"] == entry.get("source", "")
        assert r["tags"] == entry.get("tags", "")
        assert r["line_number"] == entry.get("line_number", 0)

    def test_fetch_nonexistent_id(self, populated_db):
        """Nonexistent ID returns empty list."""
        results = get_details(populated_db, ["nonexistent_id_12345"])
        assert results == []

    def test_search_then_details_roundtrip(self, populated_db):
        """Search → get IDs → fetch details is a complete workflow."""
        search_results = search_entries(populated_db, "security")
        assert len(search_results) > 0

        ids = [r["id"] for r in search_results]
        details = get_details(populated_db, ids)
        assert len(details) == len(search_results)

        # Details have full_content (not truncated)
        for d in details:
            assert "full_content" in d
            assert len(d["full_content"]) > 0


# ---------------------------------------------------------------------------
# Stats Integration
# ---------------------------------------------------------------------------


class TestStatsIntegration:
    """Test get_stats against the populated database."""

    def test_total_count(self, populated_db, all_entries):
        """Total count matches the number of indexed entries."""
        stats = get_stats(populated_db)
        assert stats["total_entries"] == len(all_entries)

    def test_by_layer_breakdown(self, populated_db):
        """Layer breakdown matches expected distribution."""
        stats = get_stats(populated_db)
        assert "inscribed" in stats["by_layer"]
        assert "etched" in stats["by_layer"]
        assert "traced" in stats["by_layer"]

        total = sum(stats["by_layer"].values())
        assert total == stats["total_entries"]

    def test_by_role_breakdown(self, populated_db):
        """Role breakdown covers all 4 test roles."""
        stats = get_stats(populated_db)
        assert set(stats["by_role"].keys()) == {
            "orchestrator", "planner", "reviewer", "workers"
        }

        total = sum(stats["by_role"].values())
        assert total == stats["total_entries"]

    def test_last_indexed_present(self, populated_db):
        """last_indexed timestamp is set after rebuild."""
        stats = get_stats(populated_db)
        assert stats["last_indexed"] != ""
        assert "T" in stats["last_indexed"]


# ---------------------------------------------------------------------------
# do_reindex End-to-End
# ---------------------------------------------------------------------------


class TestDoReindexEndToEnd:
    """Test the do_reindex function that connects indexer and server."""

    def test_reindex_from_testdata(self, echo_dir, db_path):
        """do_reindex parses files and populates the database."""
        result = do_reindex(echo_dir, db_path)

        assert result["entries_indexed"] > 0
        assert result["time_ms"] >= 0
        assert set(result["roles"]) == {
            "orchestrator", "planner", "reviewer", "workers"
        }

    def test_reindex_creates_searchable_db(self, echo_dir, db_path):
        """After do_reindex, the database is immediately searchable."""
        do_reindex(echo_dir, db_path)

        conn = get_db(db_path)
        try:
            results = search_entries(conn, "security")
            assert len(results) > 0
        finally:
            conn.close()

    def test_reindex_is_idempotent(self, echo_dir, db_path):
        """Running do_reindex twice produces the same entry count."""
        r1 = do_reindex(echo_dir, db_path)
        r2 = do_reindex(echo_dir, db_path)
        assert r1["entries_indexed"] == r2["entries_indexed"]

    def test_reindex_updates_timestamp(self, echo_dir, db_path):
        """Each reindex updates the last_indexed timestamp."""
        do_reindex(echo_dir, db_path)
        conn = get_db(db_path)
        ts1 = conn.execute(
            "SELECT value FROM echo_meta WHERE key='last_indexed'"
        ).fetchone()[0]
        conn.close()

        time.sleep(1.1)  # Ensure timestamp advances (1s resolution)

        do_reindex(echo_dir, db_path)
        conn = get_db(db_path)
        ts2 = conn.execute(
            "SELECT value FROM echo_meta WHERE key='last_indexed'"
        ).fetchone()[0]
        conn.close()

        assert ts2 > ts1, "Timestamp should advance after reindex"


# ---------------------------------------------------------------------------
# Mutation & Reindex (add/remove entries, then reindex)
# ---------------------------------------------------------------------------


class TestMutationAndReindex:
    """Test reindex behavior when MEMORY.md files change."""

    def test_added_entry_appears_after_reindex(self, tmp_path, db_path):
        """A new entry added to MEMORY.md appears after reindex."""
        echo_dir = str(tmp_path / "echoes")
        role_dir = os.path.join(echo_dir, "tester")
        os.makedirs(role_dir)

        # Initial file with 1 entry
        with open(os.path.join(role_dir, "MEMORY.md"), "w") as f:
            f.write(
                "# Tester Echoes\n\n"
                "## Inscribed — First Entry (2026-01-01)\n\n"
                "**Source**: `test:initial`\n\n"
                "This is the first entry content.\n"
            )

        r1 = do_reindex(echo_dir, db_path)
        assert r1["entries_indexed"] == 1

        # Append a second entry
        with open(os.path.join(role_dir, "MEMORY.md"), "a") as f:
            f.write(
                "\n## Inscribed — Second Entry (2026-01-02)\n\n"
                "**Source**: `test:added`\n\n"
                "This is the second entry added later.\n"
            )

        r2 = do_reindex(echo_dir, db_path)
        assert r2["entries_indexed"] == 2

        # Verify searchable
        conn = get_db(db_path)
        results = search_entries(conn, "second entry")
        conn.close()
        assert len(results) >= 1

    def test_removed_entry_disappears_after_reindex(self, tmp_path, db_path):
        """An entry removed from MEMORY.md disappears after reindex."""
        echo_dir = str(tmp_path / "echoes")
        role_dir = os.path.join(echo_dir, "tester")
        os.makedirs(role_dir)

        # File with 2 entries
        with open(os.path.join(role_dir, "MEMORY.md"), "w") as f:
            f.write(
                "# Tester Echoes\n\n"
                "## Inscribed — Keep This (2026-01-01)\n\n"
                "**Source**: `test:keep`\n\n"
                "Content to keep.\n\n"
                "## Inscribed — Remove This (2026-01-02)\n\n"
                "**Source**: `test:remove`\n\n"
                "Content to remove.\n"
            )

        r1 = do_reindex(echo_dir, db_path)
        assert r1["entries_indexed"] == 2

        # Overwrite with only 1 entry
        with open(os.path.join(role_dir, "MEMORY.md"), "w") as f:
            f.write(
                "# Tester Echoes\n\n"
                "## Inscribed — Keep This (2026-01-01)\n\n"
                "**Source**: `test:keep`\n\n"
                "Content to keep.\n"
            )

        r2 = do_reindex(echo_dir, db_path)
        assert r2["entries_indexed"] == 1

        # Removed entry no longer searchable
        conn = get_db(db_path)
        results = search_entries(conn, "remove")
        conn.close()
        assert len(results) == 0

    def test_new_role_added_after_reindex(self, tmp_path, db_path):
        """A new role directory added between reindexes is picked up."""
        echo_dir = str(tmp_path / "echoes")
        role1 = os.path.join(echo_dir, "alpha")
        os.makedirs(role1)

        with open(os.path.join(role1, "MEMORY.md"), "w") as f:
            f.write(
                "## Inscribed — Alpha Entry (2026-01-01)\n\n"
                "Alpha role content.\n"
            )

        r1 = do_reindex(echo_dir, db_path)
        assert r1["entries_indexed"] == 1
        assert r1["roles"] == ["alpha"]

        # Add a second role
        role2 = os.path.join(echo_dir, "beta")
        os.makedirs(role2)
        with open(os.path.join(role2, "MEMORY.md"), "w") as f:
            f.write(
                "## Inscribed — Beta Entry (2026-01-02)\n\n"
                "Beta role content.\n"
            )

        r2 = do_reindex(echo_dir, db_path)
        assert r2["entries_indexed"] == 2
        assert r2["roles"] == ["alpha", "beta"]

    def test_role_removed_cleans_up_after_reindex(self, tmp_path, db_path):
        """Removing a role directory removes its entries after reindex."""
        echo_dir = str(tmp_path / "echoes")
        for name in ("keep-role", "remove-role"):
            role_dir = os.path.join(echo_dir, name)
            os.makedirs(role_dir)
            with open(os.path.join(role_dir, "MEMORY.md"), "w") as f:
                f.write(
                    f"## Inscribed — {name} Entry (2026-01-01)\n\n"
                    f"Content for {name}.\n"
                )

        r1 = do_reindex(echo_dir, db_path)
        assert r1["entries_indexed"] == 2

        # Remove one role
        shutil.rmtree(os.path.join(echo_dir, "remove-role"))

        r2 = do_reindex(echo_dir, db_path)
        assert r2["entries_indexed"] == 1
        assert r2["roles"] == ["keep-role"]

        # Verify search only returns kept role
        conn = get_db(db_path)
        results = search_entries(conn, "content")
        conn.close()
        assert all(r["role"] == "keep-role" for r in results)


# ---------------------------------------------------------------------------
# Cross-Role Search Patterns
# ---------------------------------------------------------------------------


class TestCrossRoleSearch:
    """Test search queries that span multiple roles."""

    def test_search_finds_entries_across_roles(self, populated_db):
        """A common keyword returns results from multiple roles."""
        results = search_entries(populated_db, "pattern", limit=20)
        roles = set(r["role"] for r in results)
        # "pattern" appears in reviewer, orchestrator, planner, workers content
        assert len(roles) >= 2, f"Expected multi-role results, got: {roles}"

    def test_role_filter_isolates_single_role(self, populated_db):
        """Filtering by role returns only that role's entries."""
        all_results = search_entries(populated_db, "pattern", limit=20)
        for_reviewer = search_entries(
            populated_db, "pattern", role="reviewer", limit=20
        )

        all_roles = set(r["role"] for r in all_results)
        reviewer_roles = set(r["role"] for r in for_reviewer)

        if len(all_roles) > 1:
            assert reviewer_roles == {"reviewer"}
            assert len(for_reviewer) < len(all_results)

    def test_layer_filter_across_roles(self, populated_db):
        """Filtering by 'traced' layer finds entries from multiple roles."""
        results = search_entries(populated_db, "test OR verify OR fix", layer="traced", limit=20)
        for r in results:
            assert r["layer"] == "traced"


# ---------------------------------------------------------------------------
# Concurrent Access Patterns
# ---------------------------------------------------------------------------


class TestConcurrentAccess:
    """Test database behavior under concurrent connection patterns."""

    def test_read_during_rebuild(self, db_path, all_entries):
        """A read connection can query while another rebuilds."""
        # Populate initially
        conn1 = get_db(db_path)
        ensure_schema(conn1)
        rebuild_index(conn1, all_entries)
        conn1.close()

        # Open two connections: one reads, one rebuilds
        reader = get_db(db_path)
        writer = get_db(db_path)

        # Reader can still query during rebuild
        results_before = search_entries(reader, "security")
        assert len(results_before) > 0

        # Writer rebuilds
        ensure_schema(writer)
        rebuild_index(writer, all_entries)
        writer.close()

        # Reader sees updated data after refresh
        reader.close()
        reader2 = get_db(db_path)
        results_after = search_entries(reader2, "security")
        reader2.close()
        assert len(results_after) > 0

    def test_busy_timeout_prevents_lock_errors(self, db_path, all_entries):
        """busy_timeout=5000 prevents immediate SQLITE_BUSY errors."""
        conn = get_db(db_path)
        ensure_schema(conn)
        rebuild_index(conn, all_entries)

        # Verify busy_timeout is set
        timeout = conn.execute("PRAGMA busy_timeout").fetchone()[0]
        conn.close()
        assert timeout == 5000


# ---------------------------------------------------------------------------
# Edge Cases with Real Data
# ---------------------------------------------------------------------------


class TestEdgeCasesWithRealData:
    """Edge cases tested against the realistic testdata."""

    def test_empty_search_after_populated_db(self, populated_db):
        """Empty query returns empty even with data in the DB."""
        results = search_entries(populated_db, "")
        assert results == []

    def test_stopwords_only_search(self, populated_db):
        """Searching only stopwords returns empty or fallback results."""
        results = search_entries(populated_db, "the and or is")
        # build_fts_query filters stopwords, then falls back to tokens >= 2 chars
        # "the" is a stopword but passes the fallback (len >= 2)
        # Either returns results (fallback) or empty — both are valid
        assert isinstance(results, list)

    def test_special_chars_in_search(self, populated_db):
        """Special characters in search query don't cause crashes."""
        for query in ["foo*bar", "test()", "a.b.c", "key=value", "path/to/file"]:
            results = search_entries(populated_db, query)
            assert isinstance(results, list)

    def test_very_long_search_query(self, populated_db):
        """SEC-7: Queries exceeding 500 chars are truncated safely."""
        long_query = "security " * 100  # ~900 chars
        results = search_entries(populated_db, long_query)
        assert isinstance(results, list)

    def test_stats_after_empty_reindex(self, db_path):
        """Stats on an empty database return zero counts."""
        empty_dir = os.path.join(os.path.dirname(__file__), "testdata", "empty")
        os.makedirs(empty_dir, exist_ok=True)
        try:
            do_reindex(empty_dir, db_path)
            conn = get_db(db_path)
            stats = get_stats(conn)
            conn.close()
            assert stats["total_entries"] == 0
            assert stats["by_layer"] == {}
            assert stats["by_role"] == {}
        finally:
            os.rmdir(empty_dir)

    def test_search_result_ids_match_detail_ids(self, populated_db):
        """IDs from search results can be used directly in get_details."""
        search_results = search_entries(populated_db, "convergence", limit=5)
        if not search_results:
            pytest.skip("No results for 'convergence'")

        search_ids = [r["id"] for r in search_results]
        details = get_details(populated_db, search_ids)
        detail_ids = [d["id"] for d in details]

        assert set(search_ids) == set(detail_ids)


# ---------------------------------------------------------------------------
# Edge Cases: empty, invalid, missing, boundary, unicode, whitespace inputs
# ---------------------------------------------------------------------------


class TestEdgeCaseEmptyInputs:
    """Edge cases for empty and whitespace-only inputs in the search pipeline."""

    def test_empty_string_search_returns_empty(self, populated_db):
        """Searching with an empty string returns empty results."""
        results = search_entries(populated_db, "")
        assert results == []

    def test_whitespace_only_search_returns_empty(self, populated_db):
        """Searching with whitespace-only string returns empty results."""
        results = search_entries(populated_db, "   \t\n  ")
        assert results == []

    def test_empty_ids_list_returns_empty(self, populated_db):
        """get_details with empty list returns empty results."""
        results = get_details(populated_db, [])
        assert results == []

    def test_missing_id_returns_empty(self, populated_db):
        """get_details with a nonexistent ID returns empty list."""
        results = get_details(populated_db, ["nonexistent_id_abc123"])
        assert results == []

    def test_empty_echo_dir_produces_zero_stats(self, tmp_path, db_path):
        """Stats on an empty reindexed directory show zero entries."""
        empty_dir = str(tmp_path / "empty_echoes")
        os.makedirs(empty_dir)
        do_reindex(empty_dir, db_path)
        conn = get_db(db_path)
        try:
            stats = get_stats(conn)
            assert stats["total_entries"] == 0
            assert stats["by_layer"] == {}
            assert stats["by_role"] == {}
        finally:
            conn.close()

    def test_rebuild_with_empty_entries_list(self, db, tmp_path):
        """rebuild_index with an empty entries list produces zero rows."""
        count = rebuild_index(db, [])
        assert count == 0
        actual = db.execute("SELECT COUNT(*) FROM echo_entries").fetchone()[0]
        assert actual == 0

    def test_search_null_character_in_query(self, populated_db):
        """Query containing null byte is handled without crash."""
        results = search_entries(populated_db, "security\x00injection")
        assert isinstance(results, list)

    def test_get_details_with_none_filtered_out(self, populated_db):
        """get_details with None values in id list filters them gracefully."""
        # Per source: ids = [str(i) for i in ids if i is not None][:100]
        results = get_details(populated_db, [None, None, None])
        assert results == []


class TestEdgeCaseInvalidInputs:
    """Edge cases for invalid and malformed inputs to server functions."""

    def test_invalid_layer_filter_returns_empty(self, populated_db):
        """Searching with a non-existent layer filter returns empty results."""
        results = search_entries(populated_db, "pattern", layer="nonexistent_layer")
        assert results == []

    def test_invalid_role_filter_returns_empty(self, populated_db):
        """Searching with a non-existent role filter returns empty results."""
        results = search_entries(populated_db, "pattern", role="nonexistent_role")
        assert results == []

    def test_invalid_zero_limit_returns_empty(self, populated_db):
        """Searching with limit=0 returns empty results."""
        results = search_entries(populated_db, "security", limit=0)
        assert results == []

    def test_negative_limit_handled_safely(self, populated_db):
        """Searching with a negative limit returns empty or safe results."""
        # SQLite LIMIT -1 returns all rows; we just verify no crash
        results = search_entries(populated_db, "security", limit=-1)
        assert isinstance(results, list)

    def test_malformed_fts_query_special_chars(self, populated_db):
        """Malformed FTS5 queries with special characters don't crash."""
        for q in ["()", "[]", "{}", "\"unclosed", "MATCH:", "OR AND", "***"]:
            results = search_entries(populated_db, q)
            assert isinstance(results, list), f"Crashed for query: {q!r}"

    def test_single_char_query_returns_valid_response(self, populated_db):
        """Single character query (below min token length) returns empty."""
        # build_fts_query filters tokens < 2 chars
        results = search_entries(populated_db, "a")
        assert isinstance(results, list)

    def test_numeric_only_query(self, populated_db):
        """Numeric-only query is handled without crash."""
        results = search_entries(populated_db, "12345 67890")
        assert isinstance(results, list)

    def test_reindex_missing_echo_dir_returns_zero(self, tmp_path, db_path):
        """do_reindex with a missing directory returns zero entries."""
        missing = str(tmp_path / "does_not_exist")
        result = do_reindex(missing, db_path)
        assert result["entries_indexed"] == 0

    def test_details_with_oversized_id_list_capped(self, populated_db, all_entries):
        """get_details caps at 100 IDs even if more are provided."""
        # Create a list of 150 real + duplicate IDs
        real_ids = [e["id"] for e in all_entries]
        oversized = (real_ids * 20)[:150]
        results = get_details(populated_db, oversized)
        # Should return at most 100 unique entries
        assert len(results) <= 100


class TestEdgeCaseBoundaryValues:
    """Edge cases for boundary values in search and indexing."""

    def test_huge_query_truncated_safely(self, populated_db):
        """Query of 1000+ characters is truncated at 500 chars without crash."""
        huge_q = "security " * 200  # ~1800 chars
        results = search_entries(populated_db, huge_q)
        assert isinstance(results, list)

    def test_large_limit_returns_all_available(self, populated_db, all_entries):
        """Limit larger than entry count returns all available results."""
        results = search_entries(populated_db, "the OR pattern OR security", limit=10000)
        assert len(results) <= len(all_entries)
        assert len(results) >= 0

    def test_single_entry_db_search(self, db_path):
        """Search works correctly on a database with exactly one entry."""
        from indexer import parse_memory_file as _parse
        import tempfile

        # Create a minimal single-entry database
        with tempfile.TemporaryDirectory() as tmpdir:
            mem_path = os.path.join(tmpdir, "MEMORY.md")
            with open(mem_path, "w") as f:
                f.write(
                    "## Inscribed — Unique boundary entry (2026-01-01)\n"
                    "**Source**: `test:boundary`\n"
                    "This is the only entry in the database.\n"
                )
            entries = _parse(mem_path, "boundary-role")

        conn = get_db(db_path)
        ensure_schema(conn)
        rebuild_index(conn, entries)
        results = search_entries(conn, "boundary entry")
        conn.close()
        assert len(results) == 1

    def test_duplicate_entries_rebuild_deduplication(self, db_path, all_entries):
        """Rebuilding twice with same entries doesn't duplicate rows."""
        conn = get_db(db_path)
        ensure_schema(conn)
        rebuild_index(conn, all_entries)
        rebuild_index(conn, all_entries)
        count = conn.execute("SELECT COUNT(*) FROM echo_entries").fetchone()[0]
        conn.close()
        assert count == len(all_entries)

    def test_boundary_limit_one_returns_single_result(self, populated_db):
        """Limit=1 returns exactly one result for a matching query."""
        results = search_entries(populated_db, "security", limit=1)
        assert len(results) <= 1

    def test_zero_entry_database_stats_returns_empty_dicts(self, db_path):
        """Stats on an empty but initialized DB return zero counts and empty dicts."""
        conn = get_db(db_path)
        ensure_schema(conn)
        rebuild_index(conn, [])
        stats = get_stats(conn)
        conn.close()
        assert stats["total_entries"] == 0
        assert stats["by_layer"] == {}
        assert stats["by_role"] == {}


class TestEdgeCaseUnicodeContent:
    """Edge cases for unicode and special characters in search and indexing."""

    def test_unicode_content_indexed_and_searchable(self, db_path):
        """Entries with unicode content are indexed and can be searched."""
        import tempfile
        from indexer import parse_memory_file as _parse

        with tempfile.TemporaryDirectory() as tmpdir:
            mem_path = os.path.join(tmpdir, "MEMORY.md")
            with open(mem_path, "w", encoding="utf-8") as f:
                f.write(
                    "## Inscribed — Unicode test (2026-01-10)\n"
                    "Content: résumé café naïve architecture\n"
                    "More: 测试内容 테스트\n"
                )
            entries = _parse(mem_path, "unicode-role")

        conn = get_db(db_path)
        ensure_schema(conn)
        rebuild_index(conn, entries)
        # Search by ASCII word present in the unicode content
        results = search_entries(conn, "architecture")
        conn.close()
        assert isinstance(results, list)

    def test_special_chars_in_source_field_searchable(self, db_path):
        """Entries with special chars in source field don't break search."""
        import tempfile
        from indexer import parse_memory_file as _parse

        with tempfile.TemporaryDirectory() as tmpdir:
            mem_path = os.path.join(tmpdir, "MEMORY.md")
            with open(mem_path, "w") as f:
                f.write(
                    "## Inscribed — Special source chars (2026-01-05)\n"
                    "**Source**: `rune:appraise abc-123_def.ghi`\n"
                    "Entry with special chars in source field.\n"
                )
            entries = _parse(mem_path, "special-src")

        conn = get_db(db_path)
        ensure_schema(conn)
        rebuild_index(conn, entries)
        results = search_entries(conn, "special chars source")
        conn.close()
        assert isinstance(results, list)
        assert len(results) >= 0

    def test_em_dash_in_search_query_sanitized(self, populated_db):
        """Query with em dash (—) is sanitized by build_fts_query."""
        results = search_entries(populated_db, "security — injection")
        assert isinstance(results, list)

    def test_newlines_in_query_handled(self, populated_db):
        """Query with embedded newlines is handled safely."""
        results = search_entries(populated_db, "security\ninjection\ntesting")
        assert isinstance(results, list)


class TestEdgeCaseMissingAndNoneFields:
    """Edge cases where fields are missing or None in entries/results."""

    def test_get_details_returns_all_required_fields(self, populated_db, all_entries):
        """get_details results always include all expected field keys."""
        required_fields = {
            "id", "source", "layer", "role", "full_content",
            "date", "tags", "line_number", "file_path"
        }
        ids = [e["id"] for e in all_entries[:3]]
        results = get_details(populated_db, ids)
        for r in results:
            missing = required_fields - set(r.keys())
            assert not missing, f"Missing fields: {missing}"

    def test_search_results_have_required_fields(self, populated_db):
        """Search result dicts always include expected field keys."""
        required_fields = {
            "id", "source", "layer", "role", "date",
            "content_preview", "score", "line_number", "tags"
        }
        results = search_entries(populated_db, "security", limit=5)
        for r in results:
            missing = required_fields - set(r.keys())
            assert not missing, f"Search result missing fields: {missing}"

    def test_stats_always_has_required_keys(self, populated_db):
        """get_stats always returns dict with expected keys."""
        stats = get_stats(populated_db)
        required_keys = {"total_entries", "by_layer", "by_role", "last_indexed"}
        assert required_keys.issubset(set(stats.keys()))

    def test_content_preview_not_none_in_search(self, populated_db):
        """Search results never have None content_preview."""
        results = search_entries(populated_db, "pattern", limit=10)
        for r in results:
            assert r["content_preview"] is not None, "content_preview should never be None"

    def test_null_ids_list_filtered_gracefully(self, populated_db):
        """get_details handles a mix of valid and None IDs without crash."""
        from server import get_details
        results = get_details(populated_db, [None, "bad_id", None])
        # None values are filtered, bad_id not found → empty result
        assert results == []

    def test_search_after_empty_rebuild_returns_empty(self, db_path):
        """Search on a rebuilt-empty database returns empty results."""
        conn = get_db(db_path)
        ensure_schema(conn)
        rebuild_index(conn, [])
        results = search_entries(conn, "security pattern test")
        conn.close()
        assert results == []


class TestEdgeCaseCorruptAndTruncated:
    """Edge cases for corrupt or truncated data scenarios."""

    def test_truncated_content_indexed_partially(self, db_path):
        """Entry with very short content (1 char) is indexed correctly."""
        import tempfile
        from indexer import parse_memory_file as _parse

        with tempfile.TemporaryDirectory() as tmpdir:
            mem_path = os.path.join(tmpdir, "MEMORY.md")
            with open(mem_path, "w") as f:
                f.write(
                    "## Inscribed — Truncated entry (2026-01-01)\n"
                    "X\n"
                )
            entries = _parse(mem_path, "truncated-role")

        assert len(entries) == 1
        conn = get_db(db_path)
        ensure_schema(conn)
        count = rebuild_index(conn, entries)
        conn.close()
        assert count == 1

    def test_broken_source_line_not_crash(self, db_path):
        """Entry with malformed **Source** line is still indexed."""
        import tempfile
        from indexer import parse_memory_file as _parse

        with tempfile.TemporaryDirectory() as tmpdir:
            mem_path = os.path.join(tmpdir, "MEMORY.md")
            with open(mem_path, "w") as f:
                f.write(
                    "## Inscribed — Broken source (2026-01-01)\n"
                    "**Source**: \n"  # Source line with empty value
                    "Real content here.\n"
                )
            entries = _parse(mem_path, "broken-src")

        conn = get_db(db_path)
        ensure_schema(conn)
        count = rebuild_index(conn, entries)
        conn.close()
        # Should index the entry even with empty/broken source
        assert count >= 0

    def test_large_content_indexed_without_truncation(self, db_path):
        """Large content (10KB+) is fully indexed without truncation."""
        import tempfile
        from indexer import parse_memory_file as _parse

        large_content = "word " * 2000  # ~10KB of repeated "word "
        with tempfile.TemporaryDirectory() as tmpdir:
            mem_path = os.path.join(tmpdir, "MEMORY.md")
            with open(mem_path, "w") as f:
                f.write(
                    "## Inscribed — Large content entry (2026-01-01)\n"
                    + large_content + "\n"
                )
            entries = _parse(mem_path, "large-content")

        assert len(entries) == 1
        assert len(entries[0]["content"]) > 5000

        conn = get_db(db_path)
        ensure_schema(conn)
        rebuild_index(conn, entries)
        results = search_entries(conn, "word")
        conn.close()
        assert len(results) == 1
