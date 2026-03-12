"""Tests for doc pack install flow, manifests, and discovery."""

import json
import os
import sqlite3
import tempfile

import pytest

from server import (
    ensure_schema,
    rebuild_index,
    search_entries,
    _is_doc_pack_entry,
)

# Import indexer for parsing
from indexer import parse_memory_file


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

REGISTRY_PATH = os.path.join(
    os.path.dirname(__file__), "..", "..", "data", "doc-packs", "registry.json"
)

DOC_PACKS_DIR = os.path.join(
    os.path.dirname(__file__), "..", "..", "data", "doc-packs"
)


@pytest.fixture
def registry():
    """Load the bundled doc pack registry."""
    with open(REGISTRY_PATH) as f:
        return json.load(f)


@pytest.fixture
def db():
    """In-memory SQLite database with schema."""
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    ensure_schema(conn)
    yield conn
    conn.close()


# ---------------------------------------------------------------------------
# Registry tests
# ---------------------------------------------------------------------------


class TestRegistry:
    """Test doc pack registry structure and validity."""

    def test_registry_has_version(self, registry):
        """Registry includes a version field."""
        assert "version" in registry
        assert registry["version"] == "1.0.0"

    def test_registry_has_six_packs(self, registry):
        """Registry contains exactly 6 bundled packs."""
        assert len(registry["packs"]) == 6

    def test_all_packs_have_required_fields(self, registry):
        """Each pack has name, version, description, detectors, domains."""
        for key, pack in registry["packs"].items():
            assert "name" in pack, f"{key} missing name"
            assert "version" in pack, f"{key} missing version"
            assert "description" in pack, f"{key} missing description"
            assert "detectors" in pack, f"{key} missing detectors"
            assert "domains" in pack, f"{key} missing domains"

    def test_pack_keys_are_kebab_case(self, registry):
        """Pack keys use kebab-case naming."""
        import re
        for key in registry["packs"]:
            assert re.match(r"^[a-z0-9]+(-[a-z0-9]+)*$", key), \
                f"Pack key '{key}' is not kebab-case"

    def test_all_packs_have_detectors(self, registry):
        """Each pack has at least one detector pattern."""
        for key, pack in registry["packs"].items():
            assert len(pack["detectors"]) >= 1, f"{key} has no detectors"


# ---------------------------------------------------------------------------
# MEMORY.md parsing tests
# ---------------------------------------------------------------------------


class TestDocPackMemoryFiles:
    """Test that bundled doc pack MEMORY.md files parse correctly."""

    @pytest.fixture(params=[
        "shadcn-ui", "tailwind-v4", "nextjs",
        "fastapi", "sqlalchemy", "untitledui",
    ])
    def pack_name(self, request):
        """Parametrize over all 6 bundled packs."""
        return request.param

    def test_memory_file_exists(self, pack_name):
        """Each pack has a MEMORY.md file."""
        path = os.path.join(DOC_PACKS_DIR, pack_name, "MEMORY.md")
        assert os.path.isfile(path), f"Missing MEMORY.md for {pack_name}"

    def test_memory_file_parses(self, pack_name):
        """Each MEMORY.md parses without errors via indexer."""
        path = os.path.join(DOC_PACKS_DIR, pack_name, "MEMORY.md")
        entries = parse_memory_file(path, role="doc-packs")
        assert len(entries) >= 1, f"{pack_name} has no parseable entries"

    def test_entries_have_etched_layer(self, pack_name):
        """Doc pack entries use the 'etched' layer (permanent)."""
        path = os.path.join(DOC_PACKS_DIR, pack_name, "MEMORY.md")
        entries = parse_memory_file(path, role="doc-packs")
        for entry in entries:
            assert entry["layer"].lower() == "etched", \
                f"{pack_name} entry has layer '{entry['layer']}', expected 'etched'"

    def test_entries_have_doc_pack_source(self, pack_name):
        """Doc pack entries have source matching 'doc-pack:*' pattern."""
        path = os.path.join(DOC_PACKS_DIR, pack_name, "MEMORY.md")
        entries = parse_memory_file(path, role="doc-packs")
        for entry in entries:
            assert _is_doc_pack_entry(entry), \
                f"{pack_name} entry source '{entry.get('source')}' not doc-pack pattern"


# ---------------------------------------------------------------------------
# Doc pack indexing tests
# ---------------------------------------------------------------------------


class TestDocPackIndexing:
    """Test doc pack entries work correctly in the search index."""

    def test_doc_pack_entries_indexable(self, db):
        """Doc pack entries can be indexed and searched."""
        path = os.path.join(DOC_PACKS_DIR, "fastapi", "MEMORY.md")
        entries = parse_memory_file(path, role="doc-packs")
        rebuild_index(db, entries)
        results = search_entries(db, "dependency injection", limit=5)
        assert len(results) >= 1

    def test_all_packs_produce_entries(self):
        """All 6 packs produce at least 3 entries each."""
        packs = ["shadcn-ui", "tailwind-v4", "nextjs",
                 "fastapi", "sqlalchemy", "untitledui"]
        for pack in packs:
            path = os.path.join(DOC_PACKS_DIR, pack, "MEMORY.md")
            entries = parse_memory_file(path, role="doc-packs")
            assert len(entries) >= 3, \
                f"{pack} has only {len(entries)} entries, expected >= 3"

    def test_total_entry_count(self):
        """All 6 packs together produce exactly 18 entries (3 each)."""
        total = 0
        packs = ["shadcn-ui", "tailwind-v4", "nextjs",
                 "fastapi", "sqlalchemy", "untitledui"]
        for pack in packs:
            path = os.path.join(DOC_PACKS_DIR, pack, "MEMORY.md")
            entries = parse_memory_file(path, role="doc-packs")
            total += len(entries)
        assert total == 18


# ---------------------------------------------------------------------------
# Invalid stack name tests
# ---------------------------------------------------------------------------


class TestInvalidStackNames:
    """Test rejection of invalid stack names."""

    def test_path_traversal_rejected(self, registry):
        """Stack name with path traversal characters not in registry."""
        assert "../etc/passwd" not in registry["packs"]
        assert "..%2F..%2F" not in registry["packs"]

    def test_empty_string_not_in_registry(self, registry):
        """Empty string not a valid pack key."""
        assert "" not in registry["packs"]

    def test_special_chars_not_in_registry(self, registry):
        """Keys with special characters not in registry."""
        for bad_key in ["foo;bar", "foo bar", "foo/bar", "foo\\bar"]:
            assert bad_key not in registry["packs"]
