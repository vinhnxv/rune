#!/usr/bin/env bash
# test-count-completed-agents.sh
#
# Validates the filesystem-level invariants that `countCompletedAgents()`
# in `skills/roundtable-circle/references/monitor-utility.md` depends on.
#
# The function itself is LLM-executed JavaScript pseudocode (not a shell
# script), so this test verifies the agent-leader filesystem contract:
#
#  1. Sentinel path layout: tmp/arc/{id}/.done/*.done is globbable and
#     survives TeamDelete (durable under arc-scoped dir, not team-scoped).
#  2. Artifact layout: tmp/arc/{id}/qa/*-verdict.json, *-findings.md, and
#     reviews/*-verdict.md are each countable independently.
#  3. 3-signal fusion semantics: MAX across (sentinels, artifacts, team
#     signals) — any one at expectedCount = success. Backward compat:
#     absent arcId → falls back to team-signal-only path.
#
# Corresponds to plan `plans/2026-04-19-fix-arc-qa-notification-race-plan.md` AC-3.

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TEST_HOME="${HOME}/.rune-tests-tmp"
mkdir -p "$TEST_HOME"
TEST_DIR=$(mktemp -d "$TEST_HOME/rune-ac3-XXXXXX")
trap 'rm -rf "$TEST_DIR" 2>/dev/null || true' EXIT

cd "$TEST_DIR" || exit 1

ARC_ID="arc-1234567890"
TEAM_NAME="arc-work-qa-9999"

# Safe counter — returns 0 when path is missing (set -euo pipefail + missing
# path would otherwise trip pipefail even with 2>/dev/null).
_count_glob() {
  local path="$1"
  local pattern="$2"
  if [[ ! -d "$path" ]]; then
    echo 0
    return 0
  fi
  find "$path" -mindepth 1 -maxdepth 1 -name "$pattern" 2>/dev/null | wc -l | tr -d ' \n'
}

# ---------------------------------------------------------------------------
# Invariant 1: sentinel glob works under arc-scoped dir
# ---------------------------------------------------------------------------
mkdir -p "tmp/arc/$ARC_ID/.done"
printf '{"agent":"work-qa-verifier","status":"completed","verdict_path":"tmp/arc/%s/qa/work-verdict.json","timestamp":"2026-04-19T04:21:30.000Z"}\n' "$ARC_ID" \
  > "tmp/arc/$ARC_ID/.done/work-qa-verifier.done"
printf '{"agent":"gap-analysis-qa","status":"completed","verdict_path":"tmp/arc/%s/qa/gap-analysis-verdict.json","timestamp":"2026-04-19T04:21:31.000Z"}\n' "$ARC_ID" \
  > "tmp/arc/$ARC_ID/.done/gap-analysis-qa.done"

sentinel_count=$(_count_glob "tmp/arc/$ARC_ID/.done" '*.done')
if [[ "$sentinel_count" -ne 2 ]]; then
  echo "FAIL: sentinel_count expected 2, got $sentinel_count"
  exit 1
fi

# ---------------------------------------------------------------------------
# Invariant 2: artifact layout (QA verdict, findings, reviews) — all present
# ---------------------------------------------------------------------------
mkdir -p "tmp/arc/$ARC_ID/qa" "tmp/arc/$ARC_ID/reviews"
echo '{"verdict":"EXCELLENT","score":100}' > "tmp/arc/$ARC_ID/qa/work-verdict.json"
echo '{"verdict":"EXCELLENT","score":100}' > "tmp/arc/$ARC_ID/qa/gap-analysis-verdict.json"
echo '# findings' > "tmp/arc/$ARC_ID/grace-warden-findings.md"
echo '# review' > "tmp/arc/$ARC_ID/reviews/ward-sentinel-verdict.md"

qa_count=$(_count_glob "tmp/arc/$ARC_ID/qa" '*-verdict.json')
findings_count=$(_count_glob "tmp/arc/$ARC_ID" '*-findings.md')
reviews_count=$(_count_glob "tmp/arc/$ARC_ID/reviews" '*-verdict.md')

[[ "$qa_count" -ne 2 ]] && { echo "FAIL: qa_count expected 2, got $qa_count"; exit 1; }
[[ "$findings_count" -ne 1 ]] && { echo "FAIL: findings_count expected 1, got $findings_count"; exit 1; }
[[ "$reviews_count" -ne 1 ]] && { echo "FAIL: reviews_count expected 1, got $reviews_count"; exit 1; }

artifact_count=$((qa_count + findings_count + reviews_count))
[[ "$artifact_count" -ne 4 ]] && { echo "FAIL: artifact_count expected 4, got $artifact_count"; exit 1; }

# ---------------------------------------------------------------------------
# Invariant 3: team-signal path (S3) — works when dir exists
# ---------------------------------------------------------------------------
mkdir -p "tmp/.rune-signals/$TEAM_NAME"
echo '' > "tmp/.rune-signals/$TEAM_NAME/work-qa-verifier.done"
team_signal_count=$(_count_glob "tmp/.rune-signals/$TEAM_NAME" '*.done')
[[ "$team_signal_count" -ne 1 ]] && { echo "FAIL: team_signal_count expected 1, got $team_signal_count"; exit 1; }

# ---------------------------------------------------------------------------
# Invariant 4: durability — sentinels survive team-signal dir deletion
#             (simulates TeamDelete clearing tmp/.rune-signals/{team}/)
# ---------------------------------------------------------------------------
rm -rf "tmp/.rune-signals/$TEAM_NAME"
team_signal_count_after_delete=$(_count_glob "tmp/.rune-signals/$TEAM_NAME" '*.done')
[[ "$team_signal_count_after_delete" -ne 0 ]] && { echo "FAIL: team_signal after delete expected 0, got $team_signal_count_after_delete"; exit 1; }

sentinel_count_after=$(_count_glob "tmp/arc/$ARC_ID/.done" '*.done')
[[ "$sentinel_count_after" -ne 2 ]] && { echo "FAIL: sentinels must survive team deletion — expected 2, got $sentinel_count_after"; exit 1; }

# ---------------------------------------------------------------------------
# Invariant 5: Math.max semantics — if ANY source at expectedCount, return count
# Simulating: expectedCount=2. sentinels=2, artifacts=4, team_signals=0.
# MAX(2, 4, 0) = 4, which is >= expectedCount (2) → COMPLETE.
# ---------------------------------------------------------------------------
expected=2
max_count=$sentinel_count_after
[[ "$artifact_count" -gt "$max_count" ]] && max_count=$artifact_count
[[ "$team_signal_count_after_delete" -gt "$max_count" ]] && max_count=$team_signal_count_after_delete

[[ "$max_count" -lt "$expected" ]] && { echo "FAIL: fusion max=$max_count < expected=$expected"; exit 1; }

# ---------------------------------------------------------------------------
# Invariant 6: backward compat — absent arcId, absent signal dir → count = 0
# ---------------------------------------------------------------------------
absent_team=$(_count_glob "tmp/.rune-signals/does-not-exist" '*.done')
[[ "$absent_team" -ne 0 ]] && { echo "FAIL: absent signal dir expected 0, got $absent_team"; exit 1; }

echo "PASS: AC-3 — countCompletedAgents filesystem contract invariants verified"
echo "  sentinel_count=$sentinel_count_after (durable)"
echo "  artifact_count=$artifact_count (qa=$qa_count + findings=$findings_count + reviews=$reviews_count)"
echo "  team_signal durability verified (survives delete of team signal dir)"
echo "  Math.max fusion: max=$max_count >= expected=$expected → COMPLETE"
echo "  backward compat: absent dir → 0"
