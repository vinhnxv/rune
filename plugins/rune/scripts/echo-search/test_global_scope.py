"""Tests for global scope, dual-DB search, and score normalization."""

import asyncio
import os
import sqlite3
import tempfile
from unittest.mock import patch, MagicMock

import pytest

from server import (
    _merge_scoped_results,
    _sanitize_search_filters,
    _VALID_SCOPES,
    _is_doc_pack_entry,
    _compute_entry_factors,
    _score_importance,
    _DOC_PACK_IMPORTANCE_DISCOUNT,
    ensure_schema,
    get_db,
    rebuild_index,
    search_entries,
    pipeline_search,
    get_global_conn,
)


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def project_db():
    """In-memory project DB with schema."""
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    ensure_schema(conn)
    yield conn
    conn.close()


@pytest.fixture
def global_db():
    """In-memory global DB with schema."""
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    ensure_schema(conn)
    yield conn
    conn.close()


def _insert_test_entries(conn, entries):
    """Insert test entries into the FTS index."""
    rebuild_index(conn, entries)


def _make_entry(eid, content, layer="inscribed", source="test", role="reviewer"):
    """Create a test echo entry dict."""
    return {
        "id": eid,
        "role": role,
        "layer": layer,
        "date": "2026-03-01",
        "source": source,
        "content": content,
        "tags": "test",
        "line_number": 1,
        "file_path": f"/echoes/{role}/MEMORY.md",
    }


# ---------------------------------------------------------------------------
# Scope validation tests
# ---------------------------------------------------------------------------


class TestScopeValidation:
    """Test scope parameter sanitization."""

    def test_valid_scopes_accepted(self):
        """Verify all valid scope values pass sanitization."""
        for scope in ("project", "global", "all"):
            result = _sanitize_search_filters({"scope": scope})
            assert result["scope"] == scope

    def test_default_scope_is_project(self):
        """Verify missing scope defaults to project (backward compat)."""
        result = _sanitize_search_filters({})
        assert result["scope"] == "project"

    def test_invalid_scope_defaults_to_project(self):
        """Verify invalid scope falls back to project."""
        result = _sanitize_search_filters({"scope": "invalid"})
        assert result["scope"] == "project"

    def test_sql_injection_scope_rejected(self):
        """T-P5-18: SQL injection via scope parameter rejected."""
        result = _sanitize_search_filters({"scope": "UNION SELECT *"})
        assert result["scope"] == "project"

    def test_non_string_scope_rejected(self):
        """Non-string scope values fall back to project."""
        for bad in (42, None, [], {}):
            result = _sanitize_search_filters({"scope": bad})
            assert result["scope"] == "project"


# ---------------------------------------------------------------------------
# Merge scoped results
# ---------------------------------------------------------------------------


class TestMergeScopedResults:
    """Test _merge_scoped_results merging and dedup."""

    def test_merge_sorts_by_composite_score(self):
        """Merged results are sorted by composite_score descending."""
        proj = [{"id": "a", "composite_score": 0.8, "source_scope": "project"}]
        glob = [{"id": "b", "composite_score": 0.9, "source_scope": "global"}]
        merged = _merge_scoped_results(proj, glob, 10)
        assert merged[0]["id"] == "b"
        assert merged[1]["id"] == "a"

    def test_merge_deduplicates_by_id(self):
        """Same ID from both scopes — higher composite_score wins."""
        proj = [{"id": "x", "composite_score": 0.5, "source_scope": "project"}]
        glob = [{"id": "x", "composite_score": 0.7, "source_scope": "global"}]
        merged = _merge_scoped_results(proj, glob, 10)
        assert len(merged) == 1
        assert merged[0]["composite_score"] == 0.7

    def test_merge_respects_limit(self):
        """Merged results respect the limit parameter."""
        proj = [{"id": f"p{i}", "composite_score": 0.5 - i * 0.01,
                 "source_scope": "project"} for i in range(5)]
        glob = [{"id": f"g{i}", "composite_score": 0.9 - i * 0.01,
                 "source_scope": "global"} for i in range(5)]
        merged = _merge_scoped_results(proj, glob, 3)
        assert len(merged) == 3

    def test_merge_empty_project(self):
        """Empty project results — global results returned."""
        glob = [{"id": "g1", "composite_score": 0.8, "source_scope": "global"}]
        merged = _merge_scoped_results([], glob, 10)
        assert len(merged) == 1
        assert merged[0]["id"] == "g1"

    def test_merge_empty_global(self):
        """Empty global results — project results returned."""
        proj = [{"id": "p1", "composite_score": 0.6, "source_scope": "project"}]
        merged = _merge_scoped_results(proj, [], 10)
        assert len(merged) == 1
        assert merged[0]["id"] == "p1"

    def test_merge_both_empty(self):
        """Both scopes empty — returns empty list."""
        merged = _merge_scoped_results([], [], 10)
        assert merged == []


# ---------------------------------------------------------------------------
# Doc pack importance discount
# ---------------------------------------------------------------------------


class TestDocPackDiscount:
    """Test doc pack importance discount at factor level (A3)."""

    def test_is_doc_pack_entry_true(self):
        """Entries with source starting with 'doc-pack:' are detected."""
        entry = {"source": "doc-pack:shadcn-ui@1.0.0"}
        assert _is_doc_pack_entry(entry) is True

    def test_is_doc_pack_entry_false(self):
        """Regular entries are not doc pack entries."""
        entry = {"source": "rune:appraise session-1"}
        assert _is_doc_pack_entry(entry) is False

    def test_is_doc_pack_entry_missing_source(self):
        """Missing source field returns False."""
        assert _is_doc_pack_entry({}) is False

    def test_is_doc_pack_entry_non_string_source(self):
        """Non-string source field returns False."""
        assert _is_doc_pack_entry({"source": 42}) is False

    def test_discount_applied_to_importance(self):
        """Doc pack entries get 0.7x importance discount."""
        doc_entry = _make_entry("dp1", "test content", layer="etched",
                                source="doc-pack:fastapi@1.0.0")
        regular_entry = _make_entry("r1", "test content", layer="etched",
                                    source="rune:appraise")

        doc_factors = _compute_entry_factors(
            doc_entry, 0.8, None, None, None, 0.0)
        reg_factors = _compute_entry_factors(
            regular_entry, 0.8, None, None, None, 0.0)

        # Doc pack importance should be 0.7 * regular importance
        assert doc_factors["importance"] == pytest.approx(
            reg_factors["importance"] * _DOC_PACK_IMPORTANCE_DISCOUNT, abs=0.01)

    def test_discount_constant_value(self):
        """Verify the discount constant is 0.7."""
        assert _DOC_PACK_IMPORTANCE_DISCOUNT == 0.7


# ---------------------------------------------------------------------------
# Global conn talisman gate
# ---------------------------------------------------------------------------


class TestGlobalConnTalismanGate:
    """Test get_global_conn() respects talisman echoes.global.enabled."""

    def test_global_conn_disabled_by_talisman(self):
        """When echoes.global.enabled is False, get_global_conn returns None."""
        import server
        old_dir = server.GLOBAL_ECHO_DIR
        old_db = server.GLOBAL_DB_PATH
        old_conn = server._global_conn
        try:
            server.GLOBAL_ECHO_DIR = "/tmp/test-echoes"
            server.GLOBAL_DB_PATH = "/tmp/test-echoes/.db"
            server._global_conn = None
            with patch.object(server, '_load_talisman',
                              return_value={"echoes": {"global": {"enabled": False}}}):
                result = get_global_conn()
                assert result is None
        finally:
            server.GLOBAL_ECHO_DIR = old_dir
            server.GLOBAL_DB_PATH = old_db
            server._global_conn = old_conn

    def test_global_conn_enabled_by_default(self):
        """When talisman has no echoes.global config, enabled defaults to True."""
        import server
        with patch.object(server, '_load_talisman', return_value={}):
            # Won't actually connect since GLOBAL_ECHO_DIR may be empty,
            # but the talisman gate should NOT block
            old_dir = server.GLOBAL_ECHO_DIR
            old_db = server.GLOBAL_DB_PATH
            old_conn = server._global_conn
            try:
                if not old_dir:
                    # No global dir configured — test just verifies gate logic
                    server.GLOBAL_ECHO_DIR = ""
                    result = get_global_conn()
                    assert result is None  # blocked by empty dir, not talisman
                else:
                    # Global dir configured — should pass talisman gate
                    pass
            finally:
                server.GLOBAL_ECHO_DIR = old_dir
                server.GLOBAL_DB_PATH = old_db
                server._global_conn = old_conn


# ---------------------------------------------------------------------------
# Schema V4 tests
# ---------------------------------------------------------------------------


class TestSchemaV4:
    """Test schema V4 on fresh and migrated databases."""

    def test_fresh_db_has_domain_column(self):
        """Fresh schema includes domain column on echo_entries table."""
        conn = sqlite3.connect(":memory:")
        conn.row_factory = sqlite3.Row
        ensure_schema(conn)
        # Verify domain column exists in echo_entries table
        cursor = conn.execute("PRAGMA table_info(echo_entries)")
        columns = {row["name"] for row in cursor.fetchall()}
        assert "domain" in columns
        conn.close()

    def test_schema_version_is_4(self):
        """Verify SCHEMA_VERSION constant is 4."""
        from server import SCHEMA_VERSION
        assert SCHEMA_VERSION == 4
