#!/usr/bin/env bash
# test-stop-hook-in-progress-guard.sh — regression tests for v2.62.0 IN-PROGRESS GUARD
#
# Covers plan AC-1..4 (in-progress guard with 3-layer defense) and AC-19 (regression
# test scaffold). Tests the helper `_arc_team_has_live_members` in 5 scenarios plus
# self-heal extension (AC-5).
#
# Run: bash plugins/rune/scripts/tests/test-stop-hook-in-progress-guard.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

TEST_HOME="${HOME}/.rune-tests-tmp"
mkdir -p "$TEST_HOME"
TEST_DIR="$(mktemp -d "$TEST_HOME/test-in-progress-guard.XXXXXX")"
trap 'rm -rf "$TEST_DIR" 2>/dev/null || true' EXIT

FAIL=0
PASS=0

_assert() {
  local _msg="$1" _cond="$2"
  if [[ "$_cond" == "0" ]]; then
    printf '  ✓ %s\n' "$_msg"
    PASS=$((PASS + 1))
  else
    printf '  ✗ %s\n' "$_msg"
    FAIL=$((FAIL + 1))
  fi
}

# ── Setup isolated CLAUDE_CONFIG_DIR ──
export CLAUDE_CONFIG_DIR="$TEST_DIR/.claude"
mkdir -p "$CLAUDE_CONFIG_DIR/teams"

# Source lib (helper lives here)
# shellcheck source=../lib/stop-hook-common.sh
source "$PLUGIN_ROOT/scripts/lib/stop-hook-common.sh" 2>/dev/null || {
  echo "FATAL: cannot source stop-hook-common.sh"
  exit 1
}

# ── Scenario 1: team dir missing → dead ──
echo "SCENARIO 1: no team dir → helper returns 1 (dead)"
set +e
_arc_team_has_live_members "rune-arc-work-arc-nonexistent"
_rc=$?
set -e
_assert "missing team dir returns 1" "$([[ $_rc -eq 1 ]] && echo 0 || echo 1)"

# ── Scenario 2: team dir exists, config.json valid, members > 0, fresh mtime → alive ──
echo "SCENARIO 2: fresh team with members → helper returns 0 (alive)"
TEAM_NAME="rune-arc-work-test2"
TEAM_DIR="$CLAUDE_CONFIG_DIR/teams/$TEAM_NAME"
mkdir -p "$TEAM_DIR"
cat > "$TEAM_DIR/config.json" <<'JSON'
{
  "members": [
    {"name": "rune-smith-1", "role": "worker"},
    {"name": "rune-smith-2", "role": "worker"}
  ]
}
JSON
touch "$TEAM_DIR"  # fresh mtime
set +e
_arc_team_has_live_members "$TEAM_NAME"
_rc=$?
set -e
_assert "fresh team with members returns 0" "$([[ $_rc -eq 0 ]] && echo 0 || echo 1)"

# ── Scenario 3: team dir exists but members empty → dead ──
echo "SCENARIO 3: team with empty members → helper returns 1 (dead)"
TEAM_NAME="rune-arc-work-test3"
TEAM_DIR="$CLAUDE_CONFIG_DIR/teams/$TEAM_NAME"
mkdir -p "$TEAM_DIR"
echo '{"members": []}' > "$TEAM_DIR/config.json"
touch "$TEAM_DIR"
set +e
_arc_team_has_live_members "$TEAM_NAME"
_rc=$?
set -e
_assert "empty members returns 1" "$([[ $_rc -eq 1 ]] && echo 0 || echo 1)"

# ── Scenario 4: team dir fresh but config.json missing → dead ──
echo "SCENARIO 4: team dir without config.json → helper returns 1 (dead)"
TEAM_NAME="rune-arc-work-test4"
TEAM_DIR="$CLAUDE_CONFIG_DIR/teams/$TEAM_NAME"
mkdir -p "$TEAM_DIR"
set +e
_arc_team_has_live_members "$TEAM_NAME"
_rc=$?
set -e
_assert "missing config.json returns 1" "$([[ $_rc -eq 1 ]] && echo 0 || echo 1)"

# ── Scenario 5: team dir stale (mtime > grace) → dead ──
echo "SCENARIO 5: stale team (mtime > grace) → helper returns 1 (dead)"
TEAM_NAME="rune-arc-work-test5"
TEAM_DIR="$CLAUDE_CONFIG_DIR/teams/$TEAM_NAME"
mkdir -p "$TEAM_DIR"
echo '{"members": [{"name": "w"}]}' > "$TEAM_DIR/config.json"
# Set mtime to 10 minutes ago (600s > default grace 300s)
touch -t "$(date -v-10M '+%Y%m%d%H%M' 2>/dev/null || date -d '-10 minutes' '+%Y%m%d%H%M' 2>/dev/null)" "$TEAM_DIR" 2>/dev/null || {
  # Fallback: Linux GNU touch uses different syntax
  touch -d '10 minutes ago' "$TEAM_DIR" 2>/dev/null || echo "  (skip scenario 5: touch -t not supported)"
}
set +e
_arc_team_has_live_members "$TEAM_NAME"
_rc=$?
set -e
# Only assert if touch successfully changed mtime
_current_age=$(( $(date +%s) - $(stat -f '%m' "$TEAM_DIR" 2>/dev/null || stat -c '%Y' "$TEAM_DIR" 2>/dev/null || echo "$(date +%s)") ))
if (( _current_age > 300 )); then
  _assert "stale team (age ${_current_age}s) returns 1" "$([[ $_rc -eq 1 ]] && echo 0 || echo 1)"
else
  echo "  ⊘ skipped (touch did not backdate, age=${_current_age}s)"
fi

# ── Scenario 6: SEC — invalid team name rejected ──
echo "SCENARIO 6: SEC — invalid name with shell metachar returns 1"
set +e
_arc_team_has_live_members "rune-arc-work; rm -rf /"
_rc=$?
set -e
_assert "shell metachar in name returns 1" "$([[ $_rc -eq 1 ]] && echo 0 || echo 1)"

# ── Self-heal extension (AC-5) ──
echo "SCENARIO 7: self-heal — non-QA phase 'work' has artifact mapping"
# shellcheck source=../lib/arc-phase-self-heal.sh
if source "$PLUGIN_ROOT/scripts/lib/arc-phase-self-heal.sh" 2>/dev/null; then
  _artifact_path=$(_ash_phase_artifact_path "work" "/fake/arc/dir")
  _assert "_ash_phase_artifact_path('work') non-empty" \
    "$([[ -n "$_artifact_path" ]] && echo 0 || echo 1)"
  _assert "_ash_phase_artifact_path('work') ends in .done sentinel" \
    "$([[ "$_artifact_path" == *work-complete.done ]] && echo 0 || echo 1)"

  _kind=$(_ash_phase_artifact_kind "work")
  _assert "_ash_phase_artifact_kind('work') = exists" \
    "$([[ "$_kind" == "exists" ]] && echo 0 || echo 1)"

  _kind=$(_ash_phase_artifact_kind "work_qa")
  _assert "_ash_phase_artifact_kind('work_qa') = json (backward compat)" \
    "$([[ "$_kind" == "json" ]] && echo 0 || echo 1)"

  _kind=$(_ash_phase_artifact_kind "unknown_phase")
  _assert "_ash_phase_artifact_kind('unknown_phase') = empty" \
    "$([[ -z "$_kind" ]] && echo 0 || echo 1)"

  # Test dispatcher with non-JSON artifact
  _tmp_artifact="$TEST_DIR/fake-work-complete.done"
  echo "done" > "$_tmp_artifact"
  set +e
  _ash_artifact_valid_dispatch "work" "$_tmp_artifact"
  _rc=$?
  set -e
  _assert "dispatcher validates non-JSON sentinel for 'work' phase" \
    "$([[ $_rc -eq 0 ]] && echo 0 || echo 1)"
else
  echo "  ⊘ skipped (cannot source arc-phase-self-heal.sh)"
fi

# ── Summary ──
echo ""
echo "═══════════════════════════════════════"
echo "Results: $PASS passed, $FAIL failed"
echo "═══════════════════════════════════════"
exit $(( FAIL > 0 ? 1 : 0 ))
