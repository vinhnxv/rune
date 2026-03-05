"""Tests for 5-factor composite scoring in server.py.

Covers:
  - BM25 normalization (min-max scaling, sign inversion)
  - Composite score computation
  - Weight loading and auto-normalization
  - Layer importance scoring
  - Recency scoring with exponential decay
  - Edge cases:
    - EDGE-001: Empty BM25 results -> return []
    - EDGE-002: Weights not summing to 1.0 -> auto-normalize
    - EDGE-003: Missing/malformed date -> recency=0.0
    - EDGE-004: Division by zero when max_frequency=0 -> return 0.0
    - EDGE-005: BM25 sign inversion (negative values)
    - EDGE-006: Single result -> score=1.0 for each factor
    - EDGE-009: Popularity bias (log normalization)
"""

import math
import sqlite3
import time

import pytest

from server import (
    _load_scoring_weights,
    _score_bm25_relevance,
    _score_frequency,
    _score_importance,
    _score_proximity,
    _score_recency,
    compute_composite_score,
    ensure_schema,
    get_db,
    rebuild_index,
    search_entries,
)


def _e(id, layer="inscribed", date="2026-02-20", content="content", tags="", line=1):
    """Compact entry factory for test data."""
    return {"id": id, "role": "r", "layer": layer, "date": date,
            "source": "", "content": content, "tags": tags,
            "line_number": line, "file_path": "/p"}


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
    """Sample entries with varied dates and layers for scoring tests."""
    today = time.strftime("%Y-%m-%d")
    return [
        {
            "id": "score_test_entry01",
            "role": "reviewer",
            "layer": "inscribed",
            "date": today,
            "source": "rune:appraise session-1",
            "content": "Recent security pattern for authentication",
            "tags": "Auth patterns",
            "line_number": 5,
            "file_path": "/echoes/reviewer/MEMORY.md",
        },
        {
            "id": "score_test_entry02",
            "role": "orchestrator",
            "layer": "etched",
            "date": "2025-01-01",
            "source": "rune:audit old-scan",
            "content": "Old security observation about input validation",
            "tags": "Input validation",
            "line_number": 12,
            "file_path": "/echoes/orchestrator/MEMORY.md",
        },
        {
            "id": "score_test_entry03",
            "role": "planner",
            "layer": "traced",
            "date": "2026-02-01",
            "source": "rune:strive task-99",
            "content": "Moderate security note about API rate limiting",
            "tags": "Rate limiting",
            "line_number": 20,
            "file_path": "/echoes/planner/MEMORY.md",
        },
    ]


@pytest.fixture
def populated_db(db, sample_entries):
    """Database with sample entries for scoring tests."""
    rebuild_index(db, sample_entries)
    return db


# ---------------------------------------------------------------------------
# BM25 normalization (_score_bm25_relevance)
# ---------------------------------------------------------------------------


class TestScoreBm25Relevance:
    """Test BM25 min-max normalization."""

    def test_empty_list_returns_empty(self):
        """EDGE-001: Empty scores -> empty result."""
        assert _score_bm25_relevance([]) == []

    def test_single_result_returns_one(self):
        """EDGE-006: Single result gets score 1.0."""
        result = _score_bm25_relevance([-3.0])
        assert result == [pytest.approx(1.0)]

    def test_two_results_normalized(self):
        """Min-max: most relevant (most negative) gets 1.0, least gets 0.0."""
        result = _score_bm25_relevance([-5.0, -2.0])
        assert result[0] == pytest.approx(1.0)  # -5.0 is most relevant
        assert result[1] == pytest.approx(0.0)  # -2.0 is least relevant

    def test_three_results_proportional(self):
        """Middle score gets proportional value."""
        result = _score_bm25_relevance([-6.0, -4.0, -2.0])
        assert result[0] == pytest.approx(1.0)
        assert result[1] == pytest.approx(0.5)
        assert result[2] == pytest.approx(0.0)

    def test_identical_scores_all_one(self):
        """EDGE-005: All same scores -> all get 1.0 (avoid division by zero)."""
        result = _score_bm25_relevance([-3.0, -3.0, -3.0])
        for n in result:
            assert n == pytest.approx(1.0)

    def test_results_bounded_0_1(self):
        """All normalized scores are in [0.0, 1.0]."""
        scores = [-10.0, -7.5, -5.0, -2.5, -1.0]
        result = _score_bm25_relevance(scores)
        for r in result:
            assert 0.0 <= r <= 1.0

    def test_negative_scores_handled(self):
        """BM25 negative values are correctly normalized."""
        result = _score_bm25_relevance([-100.0, -50.0, -1.0])
        assert result[0] == pytest.approx(1.0)  # Most negative = most relevant
        assert result[2] == pytest.approx(0.0)  # Least negative = least relevant

    def test_zero_and_negative(self):
        """Mix of zero and negative scores."""
        result = _score_bm25_relevance([-4.0, 0.0])
        assert result[0] == pytest.approx(1.0)
        assert result[1] == pytest.approx(0.0)


# ---------------------------------------------------------------------------
# Layer importance (_score_importance)
# ---------------------------------------------------------------------------


class TestScoreImportance:
    """Test layer-based importance scoring."""

    def test_etched_highest(self):
        """Etched layer has the highest importance."""
        assert _score_importance("Etched") == pytest.approx(1.0)

    def test_notes_high(self):
        """Notes tier (user-explicit) is high importance."""
        assert _score_importance("Notes") == pytest.approx(0.8)

    def test_inscribed_medium(self):
        """Inscribed is medium importance."""
        assert _score_importance("Inscribed") == pytest.approx(0.6)

    def test_observations_moderate(self):
        """Observations tier is moderate importance."""
        assert _score_importance("Observations") == pytest.approx(0.4)

    def test_traced_low(self):
        """Traced is the lowest standard importance."""
        assert _score_importance("Traced") == pytest.approx(0.3)

    def test_unknown_layer_defaults(self):
        """Unknown layer name gets default (same as Traced)."""
        assert _score_importance("unknown") == pytest.approx(0.3)

    def test_empty_layer_defaults(self):
        """Empty string layer gets default."""
        assert _score_importance("") == pytest.approx(0.3)

    def test_importance_ordering(self):
        """Importance: Etched > Notes > Inscribed > Observations > Traced."""
        etched = _score_importance("Etched")
        notes = _score_importance("Notes")
        inscribed = _score_importance("Inscribed")
        observations = _score_importance("Observations")
        traced = _score_importance("Traced")
        assert etched > notes > inscribed > observations > traced


# ---------------------------------------------------------------------------
# Recency scoring (_score_recency)
# ---------------------------------------------------------------------------


class TestScoreRecency:
    """Test recency scoring with layer-aware exponential decay.

    _score_recency now accepts (entry_dict, access_counts) instead of a
    plain date string. These tests wrap dates in entry dicts accordingly.
    """

    def _entry(self, date="", layer="inscribed"):
        """Helper to build a minimal entry dict for recency scoring."""
        return {"date": date, "layer": layer, "id": "test_entry"}

    def test_missing_date_returns_floor(self):
        """EDGE-003: Empty date string -> recency floor (0.1 with decay enabled)."""
        score = _score_recency(self._entry(""))
        assert score == pytest.approx(0.1)

    def test_none_entry_returns_floor(self):
        """EDGE-003: Non-dict entry -> recency floor."""
        score = _score_recency(self._entry(None))
        assert score == pytest.approx(0.1)

    def test_malformed_date_returns_floor(self):
        """EDGE-003: Non-ISO date strings -> recency floor."""
        for bad_date in ["not-a-date", "2026/01/01", "01-2026-01", "yesterday"]:
            score = _score_recency(self._entry(bad_date))
            assert score == pytest.approx(0.1), (
                f"Expected 0.1 for date: {bad_date}"
            )

    def test_today_scores_approximately_one(self):
        """Today's date should score very high (close to 1.0)."""
        today = time.strftime("%Y-%m-%d")
        score = _score_recency(self._entry(today))
        assert score > 0.9, f"Today's date should score >0.9, got {score}"

    def test_inscribed_90day_halflife(self):
        """Inscribed layer has 90-day half-life; ~90 days ago scores ~0.5."""
        import datetime
        ninety_days_ago = (datetime.datetime.utcnow() - datetime.timedelta(days=90)).strftime("%Y-%m-%d")
        score = _score_recency(self._entry(ninety_days_ago, "inscribed"))
        assert 0.4 <= score <= 0.6, f"90-day-old inscribed should score ~0.5, got {score}"

    def test_etched_always_one(self):
        """Etched layer has infinite half-life — always scores 1.0."""
        score = _score_recency(self._entry("2020-01-01", "etched"))
        assert score == pytest.approx(1.0)

    def test_very_old_date_scores_at_floor(self):
        """Very old date should score at or near the recency floor."""
        score = _score_recency(self._entry("2020-01-01", "traced"))
        assert score == pytest.approx(0.1), f"Old traced entry should score at floor, got {score}"

    def test_recency_bounded_floor_to_1(self):
        """Recency scores are always in [floor, 1.0]."""
        dates = [
            time.strftime("%Y-%m-%d"),
            "2025-01-01",
            "2020-06-15",
            "",
            "invalid",
        ]
        for d in dates:
            score = _score_recency(self._entry(d))
            assert 0.0 <= score <= 1.0, f"Score {score} out of range for date {d!r}"

    def test_recency_monotonically_decreasing(self):
        """More recent dates should always score higher or equal."""
        import datetime
        now = datetime.datetime.utcnow()
        scores = []
        for days_ago in [0, 10, 30, 60, 180, 365]:
            date = (now - datetime.timedelta(days=days_ago)).strftime("%Y-%m-%d")
            scores.append(_score_recency(self._entry(date)))
        for i in range(len(scores) - 1):
            assert scores[i] >= scores[i + 1], (
                f"Score for {i} days ago ({scores[i]}) < {i+1} days ago ({scores[i+1]})"
            )

    def test_access_boost_reduces_effective_age(self):
        """Access counts should boost recency by reducing effective age."""
        import datetime
        old_date = (datetime.datetime.utcnow() - datetime.timedelta(days=60)).strftime("%Y-%m-%d")
        entry = self._entry(old_date, "inscribed")
        entry["id"] = "boosted_entry"
        score_no_access = _score_recency(entry)
        score_with_access = _score_recency(entry, access_counts={"boosted_entry": 5})
        assert score_with_access > score_no_access, (
            f"Access boost should increase score: {score_with_access} <= {score_no_access}"
        )

    def test_layer_halflife_ordering(self):
        """Notes (180d) decays slower than Traced (30d) for the same age."""
        import datetime
        sixty_days_ago = (datetime.datetime.utcnow() - datetime.timedelta(days=60)).strftime("%Y-%m-%d")
        score_notes = _score_recency(self._entry(sixty_days_ago, "notes"))
        score_traced = _score_recency(self._entry(sixty_days_ago, "traced"))
        assert score_notes > score_traced, (
            f"Notes should decay slower: {score_notes} <= {score_traced}"
        )


# ---------------------------------------------------------------------------
# Proximity scoring (_score_proximity)
# ---------------------------------------------------------------------------


class TestScoreProximity:
    """Test file proximity scoring — verifies the no-context-files edge case."""

    def test_returns_zero_without_context_files(self):
        """Proximity returns 0.0 when no context_files are provided."""
        entry = {"file_path": "/echoes/reviewer/MEMORY.md"}
        assert _score_proximity(entry) == pytest.approx(0.0)

    def test_returns_zero_with_context_files(self):
        """Even with context_files provided, returns 0.0 (placeholder)."""
        entry = {"file_path": "/echoes/reviewer/MEMORY.md"}
        assert _score_proximity(entry, context_files=["/src/main.py"]) == pytest.approx(0.0)

    def test_returns_zero_with_none_context(self):
        """EDGE-011: context_files=None returns 0.0."""
        entry = {"file_path": "/echoes/reviewer/MEMORY.md"}
        assert _score_proximity(entry, context_files=None) == pytest.approx(0.0)

    def test_returns_zero_with_empty_context(self):
        """EDGE-011: context_files=[] returns 0.0."""
        entry = {"file_path": "/echoes/reviewer/MEMORY.md"}
        assert _score_proximity(entry, context_files=[]) == pytest.approx(0.0)


# ---------------------------------------------------------------------------
# Frequency scoring (_score_frequency)
# ---------------------------------------------------------------------------


class TestScoreFrequency:
    """Test access frequency scoring with log normalization."""

    def test_no_access_counts_returns_zero(self):
        """EDGE-004: No access counts -> 0.0."""
        assert _score_frequency("entry1") == pytest.approx(0.0)

    def test_none_access_counts_returns_zero(self):
        """None access_counts -> 0.0."""
        assert _score_frequency("entry1", access_counts=None) == pytest.approx(0.0)

    def test_zero_max_log_count_returns_zero(self):
        """EDGE-004: max_log_count=0 -> 0.0 (division by zero guard)."""
        counts = {"entry1": 5}
        assert _score_frequency("entry1", access_counts=counts, max_log_count=0.0) == pytest.approx(0.0)

    def test_entry_not_in_counts_returns_zero(self):
        """Entry not found in access_counts -> 0.0."""
        counts = {"other_entry": 10}
        assert _score_frequency("missing_entry", access_counts=counts, max_log_count=3.0) == pytest.approx(0.0)

    def test_entry_with_zero_count_returns_zero(self):
        """Entry with count=0 in access_counts -> 0.0."""
        counts = {"entry1": 0}
        assert _score_frequency("entry1", access_counts=counts, max_log_count=3.0) == pytest.approx(0.0)

    def test_highest_frequency_gets_one(self):
        """Entry with max log-count should get score 1.0."""
        count = 100
        max_log = math.log(1.0 + count)
        score = _score_frequency("entry1", access_counts={"entry1": count}, max_log_count=max_log)
        assert score == pytest.approx(1.0)

    def test_log_normalization_compresses_range(self):
        """EDGE-009: Log normalization prevents domination by popular entries.
        An entry with 100x more accesses should NOT score 100x higher."""
        max_log = math.log(1.0 + 100)
        score_1 = _score_frequency("a", access_counts={"a": 1}, max_log_count=max_log)
        score_100 = _score_frequency("b", access_counts={"b": 100}, max_log_count=max_log)

        ratio = score_100 / score_1 if score_1 > 0 else float("inf")
        # With log normalization, 100x gap in counts should compress to <10x gap in score
        assert ratio < 10, f"Expected <10x ratio, got {ratio:.2f}"

    def test_frequency_bounded_0_1(self):
        """All frequency scores are in [0.0, 1.0]."""
        max_log = math.log(1.0 + 50)
        for count in [0, 1, 5, 10, 50]:
            score = _score_frequency("e", access_counts={"e": count}, max_log_count=max_log)
            assert 0.0 <= score <= 1.0, f"Score {score} out of range for count {count}"


# ---------------------------------------------------------------------------
# Weight loading (_load_scoring_weights)
# ---------------------------------------------------------------------------


class TestLoadScoringWeights:
    """Test weight configuration loading from environment variables."""

    def test_default_weights_sum_to_one(self):
        """Default weights should sum to 1.0."""
        weights = _load_scoring_weights()
        total = sum(weights.values())
        assert total == pytest.approx(1.0)

    def test_default_weight_values(self):
        """Default weights match the spec."""
        weights = _load_scoring_weights()
        assert weights["relevance"] == pytest.approx(0.30)
        assert weights["importance"] == pytest.approx(0.30)
        assert weights["recency"] == pytest.approx(0.20)
        assert weights["proximity"] == pytest.approx(0.10)
        assert weights["frequency"] == pytest.approx(0.10)

    def test_all_five_factors_present(self):
        """All 5 factor keys are in the returned weights."""
        weights = _load_scoring_weights()
        expected_keys = {"relevance", "importance", "recency", "proximity", "frequency"}
        assert set(weights.keys()) == expected_keys

    def test_custom_weights_from_env(self, monkeypatch):
        """Weights can be overridden via env vars."""
        monkeypatch.setenv("ECHO_WEIGHT_RELEVANCE", "0.50")
        monkeypatch.setenv("ECHO_WEIGHT_IMPORTANCE", "0.20")
        monkeypatch.setenv("ECHO_WEIGHT_RECENCY", "0.10")
        monkeypatch.setenv("ECHO_WEIGHT_PROXIMITY", "0.10")
        monkeypatch.setenv("ECHO_WEIGHT_FREQUENCY", "0.10")

        weights = _load_scoring_weights()
        assert weights["relevance"] == pytest.approx(0.50)
        assert weights["importance"] == pytest.approx(0.20)

    def test_weights_auto_normalized_if_not_summing_to_one(self, monkeypatch):
        """EDGE-002: Weights not summing to 1.0 are auto-normalized."""
        monkeypatch.setenv("ECHO_WEIGHT_RELEVANCE", "0.50")
        monkeypatch.setenv("ECHO_WEIGHT_IMPORTANCE", "0.50")
        monkeypatch.setenv("ECHO_WEIGHT_RECENCY", "0.50")
        monkeypatch.setenv("ECHO_WEIGHT_PROXIMITY", "0.50")
        monkeypatch.setenv("ECHO_WEIGHT_FREQUENCY", "0.50")

        weights = _load_scoring_weights()
        total = sum(weights.values())
        assert total == pytest.approx(1.0), f"Expected 1.0, got {total}"

    def test_invalid_env_weight_falls_back_to_default(self, monkeypatch):
        """Non-numeric env var falls back to default."""
        monkeypatch.setenv("ECHO_WEIGHT_RELEVANCE", "not_a_number")
        weights = _load_scoring_weights()
        total = sum(weights.values())
        assert total == pytest.approx(1.0)

    def test_negative_weight_falls_back(self, monkeypatch):
        """Negative weight value falls back to default."""
        monkeypatch.setenv("ECHO_WEIGHT_RELEVANCE", "-0.5")
        weights = _load_scoring_weights()
        # Should use default for relevance, not -0.5
        assert weights["relevance"] >= 0.0


# ---------------------------------------------------------------------------
# Composite scoring (compute_composite_score)
# ---------------------------------------------------------------------------


class TestCompositeScoring:
    """Test the full composite scoring pipeline."""

    def _default_weights(self):
        return {
            "relevance": 0.30,
            "importance": 0.30,
            "recency": 0.20,
            "proximity": 0.10,
            "frequency": 0.10,
        }

    def test_empty_results_returns_empty(self):
        """EDGE-001: Empty input -> empty output."""
        result = compute_composite_score([], self._default_weights())
        assert result == []

    def test_returns_list_of_dicts(self, populated_db):
        """Composite scoring returns list of enriched dicts."""
        results = search_entries(populated_db, "security")
        scored = compute_composite_score(results, self._default_weights())
        assert isinstance(scored, list)
        for r in scored:
            assert isinstance(r, dict)

    def test_adds_composite_score_field(self, populated_db):
        """Each result gets a 'composite_score' field."""
        results = search_entries(populated_db, "security")
        scored = compute_composite_score(results, self._default_weights())
        for r in scored:
            assert "composite_score" in r
            assert isinstance(r["composite_score"], float)

    def test_adds_score_factors_field(self, populated_db):
        """Each result gets a 'score_factors' dict."""
        results = search_entries(populated_db, "security")
        scored = compute_composite_score(results, self._default_weights())
        for r in scored:
            assert "score_factors" in r
            factors = r["score_factors"]
            assert "relevance" in factors
            assert "importance" in factors
            assert "recency" in factors
            assert "proximity" in factors
            assert "frequency" in factors

    def test_composite_scores_bounded_0_1(self, populated_db):
        """Composite scores are in [0.0, 1.0]."""
        results = search_entries(populated_db, "security")
        scored = compute_composite_score(results, self._default_weights())
        for r in scored:
            assert 0.0 <= r["composite_score"] <= 1.0, (
                f"Score {r['composite_score']} out of bounds"
            )

    def test_preserves_original_fields(self, populated_db):
        """Original entry fields (id, role, layer, etc.) are preserved."""
        results = search_entries(populated_db, "security")
        scored = compute_composite_score(results, self._default_weights())
        for r in scored:
            assert "id" in r
            assert "role" in r
            assert "layer" in r

    def test_sorted_by_composite_descending(self, populated_db):
        """Results are sorted by composite_score in descending order."""
        results = search_entries(populated_db, "security")
        scored = compute_composite_score(results, self._default_weights())
        if len(scored) >= 2:
            scores = [r["composite_score"] for r in scored]
            assert scores == sorted(scores, reverse=True), (
                "Results should be sorted by composite_score descending"
            )

    def test_single_result_gets_high_relevance(self, db):
        """EDGE-006: Single result gets BM25 relevance of 1.0."""
        entries = [
            {
                "id": "single_score_test",
                "role": "r",
                "layer": "inscribed",
                "date": time.strftime("%Y-%m-%d"),
                "source": "test",
                "content": "unique_singleton_keyword_for_scoring",
                "tags": "singleton",
                "line_number": 1,
                "file_path": "/p",
            }
        ]
        rebuild_index(db, entries)
        results = search_entries(db, "unique_singleton_keyword_for_scoring")
        assert len(results) == 1

        scored = compute_composite_score(results, self._default_weights())
        assert len(scored) == 1
        assert scored[0]["score_factors"]["relevance"] == pytest.approx(1.0)

    def test_with_db_connection_for_frequency(self, populated_db):
        """Passing conn enables frequency lookups (even if 0 accesses)."""
        results = search_entries(populated_db, "security")
        scored = compute_composite_score(
            results, self._default_weights(), conn=populated_db
        )
        for r in scored:
            # All frequency scores should be 0.0 since no access log entries yet
            assert r["score_factors"]["frequency"] == pytest.approx(0.0)

    def test_without_db_connection_frequency_zero(self, populated_db):
        """Without conn, frequency is always 0.0."""
        results = search_entries(populated_db, "security")
        scored = compute_composite_score(results, self._default_weights())
        for r in scored:
            assert r["score_factors"]["frequency"] == pytest.approx(0.0)


# ---------------------------------------------------------------------------
# Integration: BM25 search + composite scoring end-to-end
# ---------------------------------------------------------------------------


class TestScoringEndToEnd:
    """Full pipeline: index -> search -> re-rank."""

    def test_recent_inscribed_beats_old_traced(self, db):
        """A recent Inscribed entry should rank above an old Traced entry."""
        today = time.strftime("%Y-%m-%d")
        content = "security pattern for input validation defense"
        entries = [
            _e("recent_inscribed_01", "inscribed", today, content, "security"),
            _e("old_traced_entry_01", "traced", "2020-01-01", content, "security", line=2),
        ]
        rebuild_index(db, entries)
        results = search_entries(db, "security validation")
        assert len(results) == 2
        weights = {"relevance": 0.30, "importance": 0.30, "recency": 0.20,
                   "proximity": 0.10, "frequency": 0.10}
        scored = compute_composite_score(results, weights)
        # Recent Inscribed ranks higher: importance 0.6>0.3 + recency boost
        assert scored[0]["id"] == "recent_inscribed_01"

    def test_etched_layer_boosts_ranking(self, db):
        """Etched (importance=1.0) should rank above Traced (importance=0.3)
        even with identical content and dates."""
        entries = [
            {
                "id": "etched_entry_boost",
                "role": "r",
                "layer": "etched",
                "date": "2026-02-01",
                "source": "",
                "content": "identical security finding about XSS",
                "tags": "XSS",
                "line_number": 1,
                "file_path": "/p",
            },
            {
                "id": "traced_entry_boost",
                "role": "r",
                "layer": "traced",
                "date": "2026-02-01",
                "source": "",
                "content": "identical security finding about XSS",
                "tags": "XSS",
                "line_number": 2,
                "file_path": "/p",
            },
        ]
        rebuild_index(db, entries)
        results = search_entries(db, "XSS security")

        weights = {
            "relevance": 0.20,
            "importance": 0.50,  # Heavily weight importance
            "recency": 0.10,
            "proximity": 0.10,
            "frequency": 0.10,
        }
        scored = compute_composite_score(results, weights)

        if len(scored) == 2:
            assert scored[0]["id"] == "etched_entry_boost"
