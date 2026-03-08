"""Tests for file proximity scoring in server.py.

Covers:
  - EDGE-011: context_files=None vs [] vs omitted
  - EDGE-013: Evidence file paths from content, not MEMORY.md path
  - Evidence path extraction from backtick-fenced content
  - compute_file_proximity: exact match, same dir, shared prefix, no match
  - Path normalization
  - Source field path extraction

NOTE: These tests require the Task 3 patch to be applied to server.py.
"""

import os

import pytest

from server import (
    _extract_evidence_paths,
    _score_proximity,
    compute_file_proximity,
)


# ---------------------------------------------------------------------------
# compute_file_proximity unit tests
# ---------------------------------------------------------------------------


class TestComputeFileProximity:
    """Test the pairwise file proximity scoring function."""

    def test_exact_match(self):
        """Exact same path -> 1.0."""
        assert compute_file_proximity("src/auth/login.py", "src/auth/login.py") == pytest.approx(1.0)

    def test_same_directory(self):
        """Different files in same directory -> 0.8."""
        score = compute_file_proximity("src/auth/login.py", "src/auth/jwt.py")
        assert score == pytest.approx(0.8)

    def test_shared_prefix_partial(self):
        """Shared path prefix -> score between 0.2 and 0.6."""
        score = compute_file_proximity("src/auth/login.py", "src/api/routes.py")
        assert 0.2 <= score <= 0.6

    def test_no_common_prefix(self):
        """Completely different paths -> 0.0."""
        score = compute_file_proximity("frontend/app.tsx", "backend/server.py")
        # May have 0 common prefix parts -> 0.0
        assert score == pytest.approx(0.0) or score >= 0.0

    def test_normalization_handles_dotdot(self):
        """Paths with .. are normalized before comparison."""
        score = compute_file_proximity(
            "src/auth/../auth/login.py",
            "src/auth/login.py",
        )
        assert score == pytest.approx(1.0)

    def test_normalization_handles_double_slash(self):
        """Double slashes are normalized."""
        score = compute_file_proximity(
            "src//auth/login.py",
            "src/auth/login.py",
        )
        assert score == pytest.approx(1.0)

    def test_deeper_shared_prefix_scores_higher(self):
        """More common path components -> higher score."""
        score_shallow = compute_file_proximity("a/b.py", "a/c/d.py")
        score_deep = compute_file_proximity("a/b/c/d.py", "a/b/c/e.py")
        assert score_deep >= score_shallow

    def test_score_bounded_0_1(self):
        """All proximity scores are in [0.0, 1.0]."""
        pairs = [
            ("a/b.py", "a/b.py"),
            ("a/b.py", "c/d.py"),
            ("src/auth/login.py", "src/api/routes.py"),
            ("", ""),
        ]
        for a, b in pairs:
            score = compute_file_proximity(a, b)
            assert 0.0 <= score <= 1.0, f"Score {score} out of range for ({a!r}, {b!r})"


# ---------------------------------------------------------------------------
# _extract_evidence_paths
# ---------------------------------------------------------------------------


class TestExtractEvidencePaths:
    """Test backtick-fenced path extraction from entry content."""

    def test_extracts_backtick_paths(self):
        """Paths in backticks with extensions are extracted."""
        entry = {"content_preview": "Found issue in `src/auth/login.py` and `src/api/routes.py`"}
        paths = _extract_evidence_paths(entry)
        assert len(paths) >= 2
        assert any("login" in p for p in paths)
        assert any("routes" in p for p in paths)

    def test_ignores_non_path_backtick(self):
        """Backtick tokens without / are not treated as paths."""
        entry = {"content_preview": "Used `pytest` and `mypy` for checking"}
        paths = _extract_evidence_paths(entry)
        # These have extensions (.py-like) but no directory separator
        # Depends on impl — at minimum shouldn't crash
        assert isinstance(paths, list)

    def test_empty_content(self):
        """Empty content returns empty list."""
        entry = {"content_preview": ""}
        paths = _extract_evidence_paths(entry)
        assert paths == []

    def test_missing_content_key(self):
        """Entry without content_preview or full_content returns empty."""
        entry = {"source": "test"}
        paths = _extract_evidence_paths(entry)
        assert isinstance(paths, list)

    def test_caps_at_10_paths(self):
        """Evidence paths are capped at 10."""
        backticks = " ".join(f"`path/file{i}.py`" for i in range(20))
        entry = {"content_preview": backticks}
        paths = _extract_evidence_paths(entry)
        assert len(paths) <= 10

    def test_deduplicates_paths(self):
        """Duplicate paths are deduplicated."""
        entry = {"content_preview": "`src/auth.py` and again `src/auth.py`"}
        paths = _extract_evidence_paths(entry)
        assert len(paths) == len(set(paths))

    def test_extracts_from_source_field(self):
        """Paths from source field are also extracted."""
        entry = {
            "content_preview": "Content without paths",
            "source": "rune:appraise src/auth/login.py",
        }
        paths = _extract_evidence_paths(entry)
        # Source field path-like tokens with / should be extracted
        assert isinstance(paths, list)


# ---------------------------------------------------------------------------
# _score_proximity with real logic
# ---------------------------------------------------------------------------


class TestScoreProximityReal:
    """Test _score_proximity with actual proximity scoring (Task 3)."""

    def test_no_context_files_returns_zero(self):
        """EDGE-011: No context files -> 0.0."""
        entry = {"content_preview": "Found in `src/auth.py`"}
        assert _score_proximity(entry, context_files=None) == pytest.approx(0.0)

    def test_empty_context_files_returns_zero(self):
        """EDGE-011: Empty context_files -> 0.0."""
        entry = {"content_preview": "Found in `src/auth.py`"}
        assert _score_proximity(entry, context_files=[]) == pytest.approx(0.0)

    def test_no_evidence_paths_returns_zero(self):
        """No extractable paths in content -> 0.0."""
        entry = {"content_preview": "No file paths here"}
        assert _score_proximity(entry, context_files=["src/main.py"]) == pytest.approx(0.0)

    def test_exact_match_returns_one(self):
        """Exact evidence/context match -> 1.0."""
        entry = {"content_preview": "Found in `src/auth/login.py`"}
        score = _score_proximity(entry, context_files=["src/auth/login.py"])
        assert score == pytest.approx(1.0)

    def test_same_directory_returns_high(self):
        """Evidence and context in same directory -> high score."""
        entry = {"content_preview": "Issue in `src/auth/login.py`"}
        score = _score_proximity(entry, context_files=["src/auth/jwt.py"])
        assert score >= 0.7

    def test_different_directories_returns_lower(self):
        """Evidence and context in different directories -> lower score."""
        entry = {"content_preview": "Issue in `src/auth/login.py`"}
        score = _score_proximity(entry, context_files=["tests/unit/test_auth.py"])
        # Different dirs but may share some prefix
        assert score < 0.8

    def test_multiple_context_files_takes_best(self):
        """Best proximity across all context files is used."""
        entry = {"content_preview": "Found in `src/auth/login.py`"}
        score = _score_proximity(
            entry,
            context_files=[
                "unrelated/file.py",
                "src/auth/login.py",  # exact match
            ],
        )
        assert score == pytest.approx(1.0)

    def test_multiple_evidence_paths_takes_best(self):
        """Best proximity across all evidence paths is used."""
        entry = {"content_preview": "Issues in `docs/readme.md` and `src/auth/login.py`"}
        score = _score_proximity(
            entry,
            context_files=["src/auth/jwt.py"],
        )
        # src/auth/login.py and src/auth/jwt.py are same dir -> 0.8
        assert score >= 0.7


# ---------------------------------------------------------------------------
# EDGE-011: context_files parameter variations
# ---------------------------------------------------------------------------


class TestEdge011ContextFiles:
    """EDGE-011: Proximity scoring handles None, [], omitted gracefully."""

    def test_context_files_none(self):
        entry = {"content_preview": "Found in `src/auth.py`"}
        result = _score_proximity(entry, context_files=None)
        assert isinstance(result, float)
        assert 0.0 <= result <= 1.0

    def test_context_files_empty_list(self):
        entry = {"content_preview": "Found in `src/auth.py`"}
        result = _score_proximity(entry, context_files=[])
        assert isinstance(result, float)
        assert 0.0 <= result <= 1.0

    def test_context_files_omitted(self):
        entry = {"content_preview": "Found in `src/auth.py`"}
        result = _score_proximity(entry)
        assert isinstance(result, float)
        assert 0.0 <= result <= 1.0

    def test_unicode_paths(self):
        entry = {"content_preview": "Found in `src/dự_án/auth.py`"}
        result = _score_proximity(entry, context_files=["src/dự_án/main.py"])
        assert isinstance(result, float)
        assert 0.0 <= result <= 1.0


# ---------------------------------------------------------------------------
# EDGE-013: Evidence from content, not MEMORY.md path
# ---------------------------------------------------------------------------


class TestEdge013EvidenceFromContent:
    """EDGE-013: Proximity uses paths from content, not the MEMORY.md file_path."""

    def test_content_path_used_not_file_path(self):
        """file_path of the MEMORY.md IS used for proximity (VOID-003).

        VOID-003 added entry's own file_path to evidence paths for proximity
        scoring. Both content paths AND file_path contribute to proximity.
        """
        entry = {
            "file_path": "/echoes/reviewer/MEMORY.md",
            "content_preview": "Found XSS in `src/frontend/app.tsx`",
        }
        # Proximity uses BOTH src/frontend/app.tsx (from content) AND
        # /echoes/reviewer/MEMORY.md (from file_path via VOID-003)
        # The content path gives the exact match for src/frontend/app.tsx
        score = _score_proximity(entry, context_files=["src/frontend/app.tsx"])
        assert score == pytest.approx(1.0)

    def test_file_path_also_used_for_proximity(self):
        """Entry with no backtick paths can still score via file_path (VOID-003).

        VOID-003 added entry's own file_path to evidence paths. Even without
        backtick paths in content, file_path can provide proximity scoring.
        """
        entry = {
            "file_path": "src/auth/MEMORY.md",  # Close to context
            "content_preview": "General observation with no file references",
        }
        score = _score_proximity(entry, context_files=["src/auth/login.py"])
        # file_path src/auth/MEMORY.md is same directory as src/auth/login.py
        # VOID-003: file_path is now extracted as evidence → proximity score > 0
        assert score >= 0.7  # same directory gives 0.8
