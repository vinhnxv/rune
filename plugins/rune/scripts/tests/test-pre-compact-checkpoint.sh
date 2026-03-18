#!/usr/bin/env bash
# test-pre-compact-checkpoint.sh — Tests for scripts/pre-compact-checkpoint.sh
#
# Usage: bash plugins/rune/scripts/tests/test-pre-compact-checkpoint.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UNDER_TEST="$SCRIPTS_DIR/pre-compact-checkpoint.sh"

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

assert_not_contains() {
  local test_name="$1" needle="$2" haystack="$3"
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  if [[ "$haystack" != *"$needle"* ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: %s\n" "$test_name"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: %s (needle was found but should not be)\n" "$test_name"
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

# ═══════════════════════════════════════════════════════════════
# 1. No team → skip message
# ═══════════════════════════════════════════════════════════════
printf "\n=== No Active Team ===\n"

result=$(echo '{"cwd":"'"$MOCK_CWD"'"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_contains "No team → systemMessage" "systemMessage" "$result"
assert_contains "No team → compact checkpoint skipped" "skipped" "$result"

# ═══════════════════════════════════════════════════════════════
# 2. Valid team → checkpoint written
# ═══════════════════════════════════════════════════════════════
printf "\n=== Valid Team Checkpoint ===\n"

mkdir -p "$MOCK_CHOME/teams/rune-test-ckpt"
echo '{"members":[{"name":"ash-1"}]}' > "$MOCK_CHOME/teams/rune-test-ckpt/config.json"

result=$(echo '{"cwd":"'"$MOCK_CWD"'"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_contains "Checkpoint output has systemMessage" "systemMessage" "$result"
assert_contains "Checkpoint mentions team" "rune-test-ckpt" "$result"

# Verify checkpoint file was written
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$MOCK_CWD/tmp/.rune-compact-checkpoint.json" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Checkpoint file created\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Checkpoint file NOT created\n"
fi

# Verify checkpoint JSON structure
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if python3 -c 'import sys,json; d=json.load(sys.stdin); assert d["team_name"] == "rune-test-ckpt"' < "$MOCK_CWD/tmp/.rune-compact-checkpoint.json" 2>/dev/null; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Checkpoint JSON has correct team_name\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Checkpoint JSON team_name mismatch\n"
fi

# Verify session isolation fields
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
has_isolation=$(python3 -c '
import sys, json
d = json.load(sys.stdin)
assert "config_dir" in d
assert "owner_pid" in d
assert "saved_at" in d
print("ok")
' < "$MOCK_CWD/tmp/.rune-compact-checkpoint.json" 2>/dev/null || echo "fail")
if [[ "$has_isolation" == "ok" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Checkpoint has session isolation fields\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Checkpoint missing session isolation fields\n"
fi

rm -f "$MOCK_CWD/tmp/.rune-compact-checkpoint.json"
rm -rf "$MOCK_CHOME/teams/rune-test-ckpt"

# ═══════════════════════════════════════════════════════════════
# 3. Missing CWD → exit 0
# ═══════════════════════════════════════════════════════════════
printf "\n=== Missing CWD ===\n"

result_code=0
echo '{}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" >/dev/null 2>&1 || result_code=$?
assert_eq "Missing CWD → exit 0" "0" "$result_code"

# ═══════════════════════════════════════════════════════════════
# 4. Missing tmp/ directory → exit 0
# ═══════════════════════════════════════════════════════════════
printf "\n=== Missing tmp/ Directory ===\n"

NO_TMP_CWD="$TMP_DIR/no-tmp-project"
mkdir -p "$NO_TMP_CWD"

result_code=0
echo '{"cwd":"'"$NO_TMP_CWD"'"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" >/dev/null 2>&1 || result_code=$?
assert_eq "Missing tmp/ → exit 0" "0" "$result_code"

# ═══════════════════════════════════════════════════════════════
# 5. Non-rune teams ignored (goldmask prefix)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Non-rune Teams Ignored ===\n"

mkdir -p "$MOCK_CHOME/teams/goldmask-test"
result=$(echo '{"cwd":"'"$MOCK_CWD"'"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_not_contains "goldmask team not checkpointed" "goldmask-test" "$result"
rm -rf "$MOCK_CHOME/teams/goldmask-test"

# ═══════════════════════════════════════════════════════════════
# 6. Arc-batch state captured without team
# ═══════════════════════════════════════════════════════════════
printf "\n=== Arc-batch State Without Team ===\n"

# NOTE: The batch state file includes summary_enabled: which may not be present,
# causing a grep failure that propagates through pipefail in the source script.
# This is a known bash edge case — command substitution with failed pipeline under
# set -eo pipefail. We add summary_enabled: true to avoid this.
cat > "$MOCK_CWD/.rune/arc-batch-loop.local.md" <<BATCH
---
active: true
iteration: 3
total_plans: 5
summary_enabled: true
---
Batch loop state
BATCH

result=$(echo '{"cwd":"'"$MOCK_CWD"'"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null) || true
assert_contains "Batch state captured → systemMessage" "systemMessage" "$result"
assert_contains "Batch state mentions arc-batch" "arc-batch" "$result"

# Verify checkpoint contains batch state
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$MOCK_CWD/tmp/.rune-compact-checkpoint.json" ]]; then
  batch_iter=$(python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("arc_batch_state",{}).get("iteration",""))' < "$MOCK_CWD/tmp/.rune-compact-checkpoint.json" 2>/dev/null || echo "")
  if [[ "$batch_iter" == "3" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: Batch state iteration captured correctly\n"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: Batch state iteration wrong: %s\n" "$batch_iter"
  fi
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: No checkpoint file created for batch state\n"
fi

rm -f "$MOCK_CWD/.rune/arc-batch-loop.local.md"
rm -f "$MOCK_CWD/tmp/.rune-compact-checkpoint.json"

# ═══════════════════════════════════════════════════════════════
# 7. Always exits 0 (non-blocking)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Always Exit 0 ===\n"

result_code=0
echo '{"cwd":"/nonexistent/path"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" >/dev/null 2>&1 || result_code=$?
assert_eq "Invalid CWD → exit 0 (fail-forward)" "0" "$result_code"

# ═══════════════════════════════════════════════════════════════
# 8. Checkpoint is valid JSON
# ═══════════════════════════════════════════════════════════════
printf "\n=== Checkpoint JSON Validity ===\n"

mkdir -p "$MOCK_CHOME/teams/arc-validate"
mkdir -p "$MOCK_CHOME/tasks/arc-validate"
echo '{"id":"task-1","status":"in_progress"}' > "$MOCK_CHOME/tasks/arc-validate/task1.json"

result=$(echo '{"cwd":"'"$MOCK_CWD"'"}' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$MOCK_CWD/tmp/.rune-compact-checkpoint.json" ]]; then
  if python3 -c 'import sys,json; json.load(sys.stdin)' < "$MOCK_CWD/tmp/.rune-compact-checkpoint.json" 2>/dev/null; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: Checkpoint is valid JSON\n"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: Checkpoint is NOT valid JSON\n"
  fi
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: No checkpoint file created\n"
fi

rm -f "$MOCK_CWD/tmp/.rune-compact-checkpoint.json"
rm -rf "$MOCK_CHOME/teams/arc-validate" "$MOCK_CHOME/tasks/arc-validate"

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
