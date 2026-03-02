#!/usr/bin/env bash
# test-detect-workflow-complete.sh — Tests for scripts/detect-workflow-complete.sh
#
# Usage: bash plugins/rune/scripts/tests/test-detect-workflow-complete.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UNDER_TEST="$SCRIPTS_DIR/detect-workflow-complete.sh"

# ── Test framework ──
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

assert_eq() {
  local test_name="$1" expected="$2" actual="$3"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ "$expected" = "$actual" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s\n" "$test_name"
    printf "    expected: %q\n" "$expected"
    printf "    actual:   %q\n" "$actual"
  fi
}

assert_contains() {
  local test_name="$1" needle="$2" haystack="$3"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ "$haystack" == *"$needle"* ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (needle not found)\n" "$test_name"
    printf "    needle:   %q\n" "$needle"
    printf "    haystack: %q\n" "$haystack"
  fi
}

# ── Setup ──
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

MOCK_CWD="$TMP_DIR/project"
mkdir -p "$MOCK_CWD/tmp"
mkdir -p "$MOCK_CWD/.claude"

MOCK_CHOME="$TMP_DIR/claude-config"
mkdir -p "$MOCK_CHOME"

# Resolve paths (macOS: /tmp → /private/tmp symlink)
MOCK_CWD=$(cd "$MOCK_CWD" && pwd -P)
MOCK_CHOME=$(cd "$MOCK_CHOME" && pwd -P)

# ═══════════════════════════════════════════════════════════════
# 1. Fast path — no state files
# ═══════════════════════════════════════════════════════════════
printf "\n=== Fast Path: No State Files ===\n"

result_code=0
CLAUDE_PROJECT_DIR="$MOCK_CWD" CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" </dev/null >/dev/null 2>&1 || result_code=$?
assert_eq "No state files → exit 0" "0" "$result_code"

# ═══════════════════════════════════════════════════════════════
# 2. Defer to arc loop hooks
# ═══════════════════════════════════════════════════════════════
printf "\n=== Defer to Arc Loop Hooks ===\n"

# Create a fresh arc-phase-loop file
echo "---" > "$MOCK_CWD/.claude/arc-phase-loop.local.md"
echo "active: true" >> "$MOCK_CWD/.claude/arc-phase-loop.local.md"
echo "---" >> "$MOCK_CWD/.claude/arc-phase-loop.local.md"

# Also create a state file so we don't fast-exit
cat > "$MOCK_CWD/tmp/.rune-arc-test.json" <<JSON
{"status":"active","team_name":"arc-test","config_dir":"$MOCK_CHOME","owner_pid":"$PPID"}
JSON

result_code=0
CLAUDE_PROJECT_DIR="$MOCK_CWD" CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" </dev/null >/dev/null 2>&1 || result_code=$?
assert_eq "Active arc loop → defers (exit 0)" "0" "$result_code"

rm -f "$MOCK_CWD/.claude/arc-phase-loop.local.md"
rm -f "$MOCK_CWD/tmp/.rune-arc-test.json"

# ═══════════════════════════════════════════════════════════════
# 3. Skip already-stopped state files
# ═══════════════════════════════════════════════════════════════
printf "\n=== Skip Already Stopped ===\n"

cat > "$MOCK_CWD/tmp/.rune-review-stopped.json" <<JSON
{"status":"stopped","team_name":"rune-review-stopped","config_dir":"$MOCK_CHOME","owner_pid":"$PPID","stopped_by":"manual"}
JSON

result_code=0
CLAUDE_PROJECT_DIR="$MOCK_CWD" CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" </dev/null >/dev/null 2>&1 || result_code=$?
assert_eq "Stopped state file → exit 0" "0" "$result_code"

rm -f "$MOCK_CWD/tmp/.rune-review-stopped.json"

# ═══════════════════════════════════════════════════════════════
# 4. Config dir mismatch → skip
# ═══════════════════════════════════════════════════════════════
printf "\n=== Config Dir Mismatch ===\n"

cat > "$MOCK_CWD/tmp/.rune-review-foreign.json" <<JSON
{"status":"completed","team_name":"rune-foreign","config_dir":"/some/other/config","owner_pid":"$PPID"}
JSON

result_code=0
CLAUDE_PROJECT_DIR="$MOCK_CWD" CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" </dev/null >/dev/null 2>&1 || result_code=$?
assert_eq "Foreign config_dir → exit 0" "0" "$result_code"

rm -f "$MOCK_CWD/tmp/.rune-review-foreign.json"

# ═══════════════════════════════════════════════════════════════
# 5. Completed workflow with team dir (dry-run)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Completed + Team Dir (Dry Run) ===\n"

mkdir -p "$MOCK_CHOME/teams/rune-completed-test"
cat > "$MOCK_CWD/tmp/.rune-review-completed.json" <<JSON
{"status":"completed","team_name":"rune-completed-test","config_dir":"$MOCK_CHOME","owner_pid":"$PPID"}
JSON

result_code=0
RUNE_CLEANUP_DRY_RUN=1 CLAUDE_PROJECT_DIR="$MOCK_CWD" CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" </dev/null >/dev/null 2>&1 || result_code=$?
assert_eq "Dry-run completed cleanup → exit 0" "0" "$result_code"

# In dry-run, team dir should NOT be removed
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -d "$MOCK_CHOME/teams/rune-completed-test" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Dry-run preserves team dir\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Dry-run removed team dir\n"
fi

rm -rf "$MOCK_CHOME/teams/rune-completed-test"
rm -f "$MOCK_CWD/tmp/.rune-review-completed.json"

# ═══════════════════════════════════════════════════════════════
# 6. Completed workflow without team dir (already cleaned)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Completed Without Team Dir ===\n"

# Use a dead PID (99999) so the script's ownership check passes.
# The script's $PPID != our $PPID in subshell, so we use a dead PID
# which triggers the orphan recovery path.
cat > "$MOCK_CWD/tmp/.rune-review-noclean.json" <<JSON
{"status":"completed","team_name":"rune-noclean","config_dir":"$MOCK_CHOME","owner_pid":"99999"}
JSON

CLAUDE_PROJECT_DIR="$MOCK_CWD" CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" </dev/null >/dev/null 2>&1

# State file should be updated with stopped_by
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if jq -e '.stopped_by' "$MOCK_CWD/tmp/.rune-review-noclean.json" >/dev/null 2>&1; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: State file marked with stopped_by\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: State file NOT marked with stopped_by\n"
fi

rm -f "$MOCK_CWD/tmp/.rune-review-noclean.json"

# ═══════════════════════════════════════════════════════════════
# 7. Skip signal/control files
# ═══════════════════════════════════════════════════════════════
printf "\n=== Skip Signal Files ===\n"

cat > "$MOCK_CWD/tmp/.rune-shutdown-signal-test.json" <<JSON
{"status":"active","signal":"force_shutdown"}
JSON

result_code=0
CLAUDE_PROJECT_DIR="$MOCK_CWD" CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" </dev/null >/dev/null 2>&1 || result_code=$?
assert_eq "Signal file skipped → exit 0" "0" "$result_code"

rm -f "$MOCK_CWD/tmp/.rune-shutdown-signal-test.json"

# ═══════════════════════════════════════════════════════════════
# 8. Escalation timeout validation
# ═══════════════════════════════════════════════════════════════
printf "\n=== Escalation Timeout Clamping ===\n"

# Create a talisman.yml with excessive escalation timeout
cat > "$MOCK_CWD/talisman.yml" <<YAML
cleanup:
  enabled: true
  escalation_timeout_seconds: 999
YAML

# The script clamps >23 to 5 — just verify it doesn't hang
result_code=0
CLAUDE_PROJECT_DIR="$MOCK_CWD" CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" </dev/null >/dev/null 2>&1 || result_code=$?
assert_eq "Excessive timeout clamped → exit 0" "0" "$result_code"

rm -f "$MOCK_CWD/talisman.yml"

# ═══════════════════════════════════════════════════════════════
# 9. Cleanup disabled via talisman
# ═══════════════════════════════════════════════════════════════
printf "\n=== Cleanup Disabled ===\n"

cat > "$MOCK_CWD/talisman.yml" <<YAML
cleanup:
  enabled: false
YAML

cat > "$MOCK_CWD/tmp/.rune-review-disabled.json" <<JSON
{"status":"completed","team_name":"rune-disabled","config_dir":"$MOCK_CHOME","owner_pid":"$PPID"}
JSON
mkdir -p "$MOCK_CHOME/teams/rune-disabled"

result_code=0
CLAUDE_PROJECT_DIR="$MOCK_CWD" CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" </dev/null >/dev/null 2>&1 || result_code=$?
assert_eq "Cleanup disabled → exit 0" "0" "$result_code"

# Team dir should NOT be removed
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -d "$MOCK_CHOME/teams/rune-disabled" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Cleanup disabled preserves team dir\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Cleanup disabled but team dir removed\n"
fi

rm -f "$MOCK_CWD/talisman.yml"
rm -rf "$MOCK_CHOME/teams/rune-disabled"
rm -f "$MOCK_CWD/tmp/.rune-review-disabled.json"

# ═══════════════════════════════════════════════════════════════
# 10. Fail-forward guard
# ═══════════════════════════════════════════════════════════════
printf "\n=== Fail-forward Guard ===\n"

result_code=0
CLAUDE_PROJECT_DIR="/nonexistent" CLAUDE_CONFIG_DIR="/nonexistent" bash "$UNDER_TEST" </dev/null >/dev/null 2>&1 || result_code=$?
assert_eq "Nonexistent paths → exit 0 (fail-forward)" "0" "$result_code"

# ═══════════════════════════════════════════════════════════════
# Results
# ═══════════════════════════════════════════════════════════════
printf "\n═══════════════════════════════════════════════════\n"
printf "Results: %d/%d passed, %d failed\n" "$PASS_COUNT" "$TOTAL_COUNT" "$FAIL_COUNT"
printf "═══════════════════════════════════════════════════\n"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
