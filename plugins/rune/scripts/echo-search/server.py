"""
Echo Search MCP Server — Thin Facade

A Model Context Protocol (MCP) stdio server that provides full-text search
over the Rune plugin's echo system (persistent learnings stored in
.rune/echoes/<role>/MEMORY.md files).

This file is a backward-compatible facade that re-exports all public symbols
from the decomposed submodules. Test files and external consumers can continue
to use ``from server import X`` without modification.

Submodules:
  - config:       Environment variables, security validation, constants, talisman
  - database:     SQLite connections, migrations, schema management
  - scoring:      BM25 relevance scoring, composite score computation
  - grouping:     Semantic group building, similarity, expansion
  - indexing:     Index rebuild, fingerprinting, retry tracking, reindex orchestration
  - pipeline:     Multi-stage search pipeline with decomposition and reranking
  - search:       FTS query building, search API, statistics
  - promotion:    Auto-promotion of Observations → Inscribed tier entries
  - mcp_handlers: MCP tool handlers, server setup, validation

Usage:
  # As MCP stdio server (normal mode):
  python3 server.py

  # Standalone reindex:
  python3 server.py --reindex
"""

from __future__ import annotations

# ── Re-export public API for backward compatibility ──
# All symbols below are imported by test files via ``from server import X``.
# Do not remove any without updating the corresponding test imports.

# config.py — constants, security, utilities
from config import (  # noqa: F401
    DB_PATH,
    ECHO_DIR,
    ECHO_ELICITATION_ENABLED,
    GLOBAL_DB_PATH,
    GLOBAL_ECHO_DIR,
    STOPWORDS,
    _RUNE_TRACE,
    _check_and_clear_dirty,
    _check_and_clear_global_dirty,
    _get_echoes_config,
    _global_dirty_path,
    _in_clause,
    _load_talisman,
    _signal_path,
    _talisman_cache,
    _trace,
    _write_dirty_signal,
    _write_global_dirty_signal,
)

# database.py — connections and migrations
from database import (  # noqa: F401
    SCHEMA_VERSION,
    _global_conn,
    _migrate_v1,
    _migrate_v2,
    ensure_schema,
    get_db,
    get_global_conn,
)

# scoring.py — scoring functions and constants
from scoring import (  # noqa: F401
    _DOC_PACK_IMPORTANCE_DISCOUNT,
    _LAYER_IMPORTANCE,
    _SCORING_WEIGHTS,
    _compute_entry_factors,
    _enrich_entry,
    _extract_evidence_paths,
    _get_access_counts,
    _is_doc_pack_entry,
    _load_scoring_weights,
    _record_access,
    _score_bm25_relevance,
    _score_frequency,
    _score_importance,
    _score_proximity,
    _score_recency,
    compute_composite_score,
    compute_file_proximity,
)

# grouping.py — semantic groups
from grouping import (  # noqa: F401
    _evidence_basenames,
    _tokenize_for_grouping,
    assign_semantic_groups,
    compute_entry_similarity,
    expand_semantic_groups,
    upsert_semantic_group,
)

# indexing.py — index operations and retry tracking
from indexing import (  # noqa: F401
    _FAILURE_MAX_RETRIES,
    _FAILURE_SCORE_BOOST,
    _backup_semantic_groups_to_temp,
    _insert_entries,
    _restore_semantic_groups_from_temp,
    cleanup_aged_failures,
    compute_token_fingerprint,
    do_reindex,
    get_retry_entries,
    rebuild_index,
    record_search_failure,
    reset_failure_on_match,
)

# search.py — FTS queries and search API
from search import (  # noqa: F401
    build_fts_query,
    get_details,
    get_stats,
    search_entries,
)

# pipeline.py — multi-stage search pipeline
from pipeline import pipeline_search  # noqa: F401

# promotion.py — auto-promotion
from promotion import check_promotions as _check_promotions  # noqa: F401

# mcp_handlers.py — MCP server and handlers
from mcp_handlers import (  # noqa: F401
    _VALID_SCOPES,
    _merge_scoped_results,
    _sanitize_search_filters,
    run_mcp_server,
)


# ── Entry points ──

def main_cli():
    """CLI entry point: --reindex or MCP server."""
    import argparse
    parser = argparse.ArgumentParser(description="Echo Search MCP Server")
    parser.add_argument("--reindex", action="store_true", help="Rebuild the search index")
    args = parser.parse_args()

    if args.reindex:
        do_reindex()
    else:
        run_mcp_server()


if __name__ == "__main__":
    main_cli()
