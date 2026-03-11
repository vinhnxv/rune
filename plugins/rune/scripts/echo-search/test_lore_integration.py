"""Integration test for Lore-Scholar fallback chain with doc packs."""

import os
import sqlite3

import pytest

from server import (
    ensure_schema,
    rebuild_index,
    search_entries,
    pipeline_search,
    _is_doc_pack_entry,
)

from indexer import parse_memory_file


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------

DOC_PACKS_DIR = os.path.join(
    os.path.dirname(__file__), "..", "..", "data", "doc-packs"
)


@pytest.fixture
def global_db_with_packs():
    """In-memory DB loaded with all 6 doc pack entries."""
    conn = sqlite3.connect(":memory:")
    conn.row_factory = sqlite3.Row
    ensure_schema(conn)
    all_entries = []
    for pack in ["shadcn-ui", "tailwind-v4", "nextjs",
                 "fastapi", "sqlalchemy", "untitledui"]:
        path = os.path.join(DOC_PACKS_DIR, pack, "MEMORY.md")
        entries = parse_memory_file(path, role="doc-packs")
        all_entries.extend(entries)
    rebuild_index(conn, all_entries)
    yield conn
    conn.close()


# ---------------------------------------------------------------------------
# Full chain integration tests
# ---------------------------------------------------------------------------


class TestLoreIntegration:
    """Test the full Lore-Scholar fallback chain with doc packs."""

    def test_search_returns_doc_pack_results(self, global_db_with_packs):
        """Searching for a framework topic returns relevant doc pack results."""
        results = search_entries(
            global_db_with_packs, "dependency injection FastAPI", limit=5)
        assert len(results) >= 1

    def test_results_are_doc_pack_entries(self, global_db_with_packs):
        """All results from doc pack DB are tagged as doc-pack entries."""
        results = search_entries(
            global_db_with_packs, "component patterns shadcn", limit=5)
        assert len(results) >= 1
        for r in results:
            assert _is_doc_pack_entry(r), \
                f"Result source '{r.get('source')}' not doc-pack pattern"

    @pytest.mark.asyncio
    async def test_pipeline_search_with_doc_packs(self, global_db_with_packs):
        """Pipeline search works with doc pack entries."""
        results = await pipeline_search(
            global_db_with_packs, "SQLAlchemy async session", limit=5)
        assert len(results) >= 1

    def test_tailwind_v4_searchable(self, global_db_with_packs):
        """Tailwind v4 doc pack entries are searchable."""
        results = search_entries(
            global_db_with_packs, "CSS-first configuration Tailwind", limit=5)
        assert len(results) >= 1

    def test_nextjs_searchable(self, global_db_with_packs):
        """Next.js doc pack entries are searchable."""
        results = search_entries(
            global_db_with_packs, "Server Components App Router", limit=5)
        assert len(results) >= 1

    def test_all_packs_have_searchable_content(self, global_db_with_packs):
        """Each pack's content is findable with a relevant query."""
        queries = {
            "shadcn-ui": "component variant",
            "tailwind-v4": "utility class CSS",
            "nextjs": "server component",
            "fastapi": "Pydantic dependency",
            "sqlalchemy": "session query",
            "untitledui": "design token",
        }
        for pack, query in queries.items():
            results = search_entries(
                global_db_with_packs, query, limit=5)
            assert len(results) >= 1, \
                f"No results for {pack} with query '{query}'"

    def test_source_scope_not_set_by_search_entries(self, global_db_with_packs):
        """search_entries does not set source_scope (that's _search_single_scope's job)."""
        results = search_entries(
            global_db_with_packs, "FastAPI async", limit=5)
        assert len(results) >= 1
        # source_scope is added by _search_single_scope, not search_entries
        for r in results:
            assert "source_scope" not in r
