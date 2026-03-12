"""Tests for echo elevation to global scope."""

import os
import sqlite3
import tempfile

import pytest

from server import (
    _is_doc_pack_entry,
    _score_importance,
    _DOC_PACK_IMPORTANCE_DISCOUNT,
    ensure_schema,
    rebuild_index,
    search_entries,
)

from indexer import parse_memory_file


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def global_db():
    """In-memory global DB with schema."""
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    ensure_schema(conn)
    yield conn
    conn.close()


@pytest.fixture
def global_memory_dir():
    """Temporary directory simulating global echoes structure."""
    with tempfile.TemporaryDirectory() as tmpdir:
        elevated_dir = os.path.join(tmpdir, "elevated")
        os.makedirs(elevated_dir)
        yield tmpdir, elevated_dir


def _write_elevated_entry(elevated_dir, content, domain="backend",
                          source_project="/test/project"):
    """Write a simulated elevated entry to MEMORY.md."""
    memory_file = os.path.join(elevated_dir, "MEMORY.md")
    entry_text = f"""
## Etched — {content[:40]} (2026-03-01)
- **layer**: etched
- **source**: elevated:{source_project}
- **Category**: pattern
- **Domain**: {domain}
- {content}
"""
    with open(memory_file, "a") as f:
        f.write(entry_text)
    return memory_file


# ---------------------------------------------------------------------------
# Elevation entry format tests
# ---------------------------------------------------------------------------


class TestElevationFormat:
    """Test elevated entry format and metadata."""

    def test_elevated_entry_parses(self, global_memory_dir):
        """Elevated entries parse correctly via indexer."""
        _, elevated_dir = global_memory_dir
        _write_elevated_entry(elevated_dir, "Use connection pooling for database access")
        memory_file = os.path.join(elevated_dir, "MEMORY.md")
        entries = parse_memory_file(memory_file, role="elevated")
        assert len(entries) >= 1

    def test_elevated_entry_has_etched_layer(self, global_memory_dir):
        """Elevated entries use etched layer."""
        _, elevated_dir = global_memory_dir
        _write_elevated_entry(elevated_dir, "Always validate user input")
        memory_file = os.path.join(elevated_dir, "MEMORY.md")
        entries = parse_memory_file(memory_file, role="elevated")
        for entry in entries:
            assert entry["layer"].lower() == "etched"

    def test_elevated_entry_preserves_domain(self, global_memory_dir):
        """Domain tag is preserved in elevated entries."""
        _, elevated_dir = global_memory_dir
        _write_elevated_entry(elevated_dir, "Use async patterns",
                              domain="frontend")
        memory_file = os.path.join(elevated_dir, "MEMORY.md")
        entries = parse_memory_file(memory_file, role="elevated")
        # Domain should be extractable from content
        assert len(entries) >= 1
        # Verify parsed domain field matches what was written
        assert entries[0].get("domain") == "frontend"
        # Also check raw content includes domain metadata
        with open(memory_file) as f:
            content = f.read()
        assert "frontend" in content


# ---------------------------------------------------------------------------
# Elevation indexing tests
# ---------------------------------------------------------------------------


class TestElevationIndexing:
    """Test elevated entries in the search index."""

    def test_elevated_entry_searchable(self, global_db, global_memory_dir):
        """Elevated entries can be found via search."""
        _, elevated_dir = global_memory_dir
        _write_elevated_entry(elevated_dir,
                              "Use connection pooling for database performance")
        memory_file = os.path.join(elevated_dir, "MEMORY.md")
        entries = parse_memory_file(memory_file, role="elevated")
        rebuild_index(global_db, entries)
        results = search_entries(global_db, "connection pooling", limit=5)
        assert len(results) >= 1

    def test_elevated_not_doc_pack(self, global_memory_dir):
        """Elevated entries are NOT doc pack entries (no 0.7 discount)."""
        _, elevated_dir = global_memory_dir
        _write_elevated_entry(elevated_dir, "Test content for elevation")
        memory_file = os.path.join(elevated_dir, "MEMORY.md")
        entries = parse_memory_file(memory_file, role="elevated")
        for entry in entries:
            assert not _is_doc_pack_entry(entry), \
                "Elevated entry should not be treated as doc pack"


# ---------------------------------------------------------------------------
# Dedup tests
# ---------------------------------------------------------------------------


class TestElevationDedup:
    """Test content-based deduplication for elevation."""

    def test_duplicate_content_produces_same_entries(self, global_memory_dir):
        """Writing the same content twice produces duplicate entries."""
        _, elevated_dir = global_memory_dir
        content = "Always use parameterized queries to prevent SQL injection"
        _write_elevated_entry(elevated_dir, content)
        _write_elevated_entry(elevated_dir, content)
        memory_file = os.path.join(elevated_dir, "MEMORY.md")
        entries = parse_memory_file(memory_file, role="elevated")
        # Both entries parse, but content is identical
        assert len(entries) >= 2
        # Content should match
        contents = [e["content"] for e in entries]
        assert contents[0] == contents[1]

    def test_different_content_produces_unique_entries(self, global_memory_dir):
        """Different content produces distinct entries."""
        _, elevated_dir = global_memory_dir
        _write_elevated_entry(elevated_dir, "Use async for I/O bound work")
        _write_elevated_entry(elevated_dir, "Prefer composition over inheritance")
        memory_file = os.path.join(elevated_dir, "MEMORY.md")
        entries = parse_memory_file(memory_file, role="elevated")
        assert len(entries) >= 2
        contents = [e["content"] for e in entries]
        assert contents[0] != contents[1]
