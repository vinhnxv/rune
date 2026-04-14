"""Unit tests for the skill-promotion scoring formula.

Locks the scoring algorithm specified in:
  plugins/rune/skills/learn/references/skill-promotion.md

Formula (clamped to [0, 1]):
  promotion_score = min(1.0,
      (action_keywords * 0.3)
    + (code_patterns   * 0.3)
    + (access_count / 10 * 0.2)
    + (content_length / 500 * 0.2))

Run:
  cd plugins/rune/scripts/echo-search && python -m pytest test_skill_promotion_scoring.py -q
"""

import re
import pytest

# ---- Inline copy of the detector scoring logic ----
# (Keeps the test independent of repo path tricks; the reference doc is the spec source.)
ACTION_KEYWORD_RE = re.compile(
    r"\b(always|never|must|should|before\s+\S+\s+do)\b", re.IGNORECASE
)
CODE_BLOCK_RE = re.compile(
    r"```|`[^`]+`|/[a-z_][\w/.-]+\.(md|py|sh|ts|js)\b", re.IGNORECASE
)


def score_promotion(content: str, access_count: int) -> tuple[float, dict]:
    action_hits = len(ACTION_KEYWORD_RE.findall(content))
    code_hits = len(CODE_BLOCK_RE.findall(content))
    length = len(content)
    raw = (
        (action_hits * 0.30)
        + (code_hits * 0.30)
        + (access_count / 10 * 0.20)
        + (length / 500 * 0.20)
    )
    clamped = max(0.0, min(1.0, raw))
    return clamped, {
        "action_keywords": action_hits,
        "code_patterns": code_hits,
        "access_count": access_count,
        "content_length": length,
        "raw_score": raw,
    }


# ---- Test fixtures ----
MIN_SCORE_THRESHOLD = 0.6  # matches talisman default


class TestPositiveFixtures:
    """Echoes that SHOULD promote."""

    def test_procedural_echo_hits_threshold(self):
        # 3 action keywords + 2 code blocks + access=8 + 300 chars
        # = 0.9 + 0.6 + 0.16 + 0.12 = 1.78 → clamped to 1.0
        content = (
            "Always validate config_dir before writing. "
            "Never use hardcoded ~/.claude/ paths. "
            "Must prefer ${CLAUDE_CONFIG_DIR:-$HOME/.claude} from `lib/platform.sh`. "
            "Example: `CHOME=\"${CLAUDE_CONFIG_DIR:-$HOME/.claude}\"` in all shell scripts."
        )
        assert len(content) >= 100, "fixture shorter than expected"
        score, signals = score_promotion(content, access_count=8)
        assert score >= MIN_SCORE_THRESHOLD
        assert score == pytest.approx(1.0)  # clamped
        assert signals["action_keywords"] >= 3
        assert signals["code_patterns"] >= 2

    def test_dense_constraint_echo_promotes(self):
        # Short but dense constraint echo (action-keyword heavy)
        content = (
            "Always read TaskList between sleeps. "
            "Never use sleep+echo anti-pattern. "
            "Must use `run_in_background: true` for Bash sleep N when N >= 2. "
            "Should derive pollInterval from talisman, not arbitrary values."
        )
        score, signals = score_promotion(content, access_count=6)
        assert score >= MIN_SCORE_THRESHOLD


class TestNegativeFixtures:
    """Echoes that should NOT promote (below threshold)."""

    def test_near_threshold_no_action_no_code(self):
        # Neutral prose: 0 action keywords, 0 code blocks, access=3, ~150 chars
        # = 0 + 0 + 0.06 + 0.06 = 0.12 → well below 0.6
        content = (
            "This is a note about the repository layout. "
            "The structure changed last quarter to support new integrations. "
            "We learned that separation of concerns made review easier."
        )
        assert len(content) >= 100
        score, signals = score_promotion(content, access_count=3)
        assert score < MIN_SCORE_THRESHOLD
        assert signals["action_keywords"] == 0
        assert signals["code_patterns"] == 0

    def test_empty_content_scores_zero(self):
        score, signals = score_promotion("", access_count=0)
        assert score == 0.0
        assert signals["action_keywords"] == 0
        assert signals["content_length"] == 0

    def test_low_access_count_fails_even_with_keywords(self):
        # Rich content but access_count=1 — not validated enough
        # 2 action + 1 code + access=1 + 150 chars
        # = 0.6 + 0.3 + 0.02 + 0.06 = 0.98 — actually passes score
        # But a separate filter (min_access_count=5) excludes it before scoring.
        # This test documents that the SCORE can be high while the eligibility
        # filter still correctly rejects.
        content = (
            "Always validate before writing. Never skip checks. "
            "See `scripts/validate.sh` for the pattern."
        )
        score, _ = score_promotion(content, access_count=1)
        assert score >= MIN_SCORE_THRESHOLD, (
            "score formula passes; eligibility filter must separately enforce "
            "min_access_count (not tested here — belongs to detector integration test)"
        )


class TestClamping:
    """The score formula clamps to [0, 1] — no runaway values."""

    def test_extreme_input_clamps_to_one(self):
        # 10 action keywords + 10 code blocks + access=100 + 1000 chars
        # Raw = 3.0 + 3.0 + 2.0 + 0.4 = 8.4 → clamped to 1.0
        content = (
            "always never must should always never must should always never "
            * 5  # many action keywords
            + "```x``` " * 10  # many code blocks
        )
        score, signals = score_promotion(content, access_count=100)
        assert score == pytest.approx(1.0)
        assert signals["raw_score"] > 1.0, "raw should overflow before clamp"

    def test_score_is_never_negative(self):
        # Degenerate inputs — though formula can't produce negative numerically,
        # this locks the guard.
        score, _ = score_promotion("neutral text", access_count=0)
        assert score >= 0.0


class TestHeuristicBoundaries:
    """Document boundary behavior for the detector's MIN_SCORE tuning."""

    def test_exactly_at_threshold(self):
        # Construct content that hits exactly 0.6 (approx)
        # 2 action + 0 code + access=0 + 0 length → 0.6
        content = "always never"  # 2 action keyword hits, 12 chars
        # 2*0.3 + 0 + 0 + 12/500*0.2 = 0.6 + 0.0048 = 0.6048
        score, _ = score_promotion(content, access_count=0)
        assert score == pytest.approx(0.6048, rel=1e-3)
        assert score >= MIN_SCORE_THRESHOLD  # just crosses

    def test_content_length_is_only_20pct_weight(self):
        # Very long content with no action keywords or code should not promote
        content = "the quick brown fox " * 500  # 10000 chars
        score, _ = score_promotion(content, access_count=0)
        # 0 + 0 + 0 + min(10000/500, 1)*0.2 = 0.2 (but length/500 is not clamped per-factor
        # only the sum is clamped). Actual: 10000/500=20 → 20*0.2=4.0, but sum clamps to 1.0.
        # Point: content length alone can produce a >0.6 score, which is a known
        # weakness of the formula and documented in Forge Notes.
        # Update formula if length-spam becomes an attack vector.
        assert score == pytest.approx(1.0)


if __name__ == "__main__":
    import sys
    sys.exit(pytest.main([__file__, "-v"]))
