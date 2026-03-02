#!/usr/bin/env bash
# test-arc-result-signal-writer.sh — Tests for scripts/arc-result-signal-writer.sh
#
# Usage: bash plugins/rune/scripts/tests/test-arc-result-signal-writer.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UNDER_TEST="$SCRIPTS_DIR/arc-result-signal-writer.sh"

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
mkdir -p "$MOCK_CWD/.git"   # Required by SEC-001
mkdir -p "$MOCK_CWD/.claude/arc/test-arc-1"

# ═══════════════════════════════════════════════════════════════
# 1. Fast-path exit for non-checkpoint writes
# ═══════════════════════════════════════════════════════════════
printf "\n=== Fast Path: Non-checkpoint Write ===\n"

INPUT=$(jq -n --arg fp "$MOCK_CWD/src/main.ts" --arg cwd "$MOCK_CWD" \
  '{tool_input: {file_path: $fp}, cwd: $cwd}')

result_code=0
echo "$INPUT" | bash "$UNDER_TEST" >/dev/null 2>&1 || result_code=$?
assert_eq "Non-checkpoint write → exit 0" "0" "$result_code"

# No signal file should be created
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ ! -f "$MOCK_CWD/tmp/arc-result-current.json" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: No signal file for non-checkpoint write\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Signal file created for non-checkpoint write\n"
fi

# ═══════════════════════════════════════════════════════════════
# 2. Checkpoint without completed ship/merge → no signal
# ═══════════════════════════════════════════════════════════════
printf "\n=== Incomplete Checkpoint ===\n"

CKPT_FILE="$MOCK_CWD/.claude/arc/test-arc-1/checkpoint.json"
cat > "$CKPT_FILE" <<JSON
{
  "id": "test-arc-1",
  "plan_file": "plans/test.md",
  "owner_pid": "$PPID",
  "config_dir": "/tmp/test",
  "phases": {
    "forge": {"status": "completed"},
    "work": {"status": "completed"},
    "ship": {"status": "pending"},
    "merge": {"status": "pending"}
  }
}
JSON

INPUT=$(jq -n --arg fp "$CKPT_FILE" --arg cwd "$MOCK_CWD" \
  '{tool_input: {file_path: $fp}, cwd: $cwd}')

echo "$INPUT" | bash "$UNDER_TEST" >/dev/null 2>&1

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ ! -f "$MOCK_CWD/tmp/arc-result-current.json" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: No signal for incomplete checkpoint\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Signal created for incomplete checkpoint\n"
  rm -f "$MOCK_CWD/tmp/arc-result-current.json"
fi

# ═══════════════════════════════════════════════════════════════
# 3. Ship completed → signal written
# ═══════════════════════════════════════════════════════════════
printf "\n=== Ship Completed ===\n"

cat > "$CKPT_FILE" <<JSON
{
  "id": "test-arc-1",
  "plan_file": "plans/test.md",
  "pr_url": "https://github.com/user/repo/pull/42",
  "owner_pid": "$PPID",
  "config_dir": "/tmp/test",
  "phases": {
    "forge": {"status": "completed"},
    "work": {"status": "completed"},
    "ship": {"status": "completed", "pr_url": "https://github.com/user/repo/pull/42"},
    "merge": {"status": "pending"}
  }
}
JSON

INPUT=$(jq -n --arg fp "$CKPT_FILE" --arg cwd "$MOCK_CWD" \
  '{tool_input: {file_path: $fp}, cwd: $cwd}')

echo "$INPUT" | bash "$UNDER_TEST" >/dev/null 2>&1

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$MOCK_CWD/tmp/arc-result-current.json" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Signal file created on ship completion\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Signal file NOT created on ship completion\n"
fi

# Verify signal JSON structure
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$MOCK_CWD/tmp/arc-result-current.json" ]]; then
  signal_status=$(python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("status",""))' < "$MOCK_CWD/tmp/arc-result-current.json" 2>/dev/null || echo "")
  if [[ "$signal_status" == "completed" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: Signal status is 'completed'\n"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: Signal status is '%s' (expected 'completed')\n" "$signal_status"
  fi
fi

# Verify PR URL in signal
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$MOCK_CWD/tmp/arc-result-current.json" ]]; then
  signal_pr=$(python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("pr_url",""))' < "$MOCK_CWD/tmp/arc-result-current.json" 2>/dev/null || echo "")
  if [[ "$signal_pr" == "https://github.com/user/repo/pull/42" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: Signal has correct PR URL\n"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: Signal PR URL is '%s'\n" "$signal_pr"
  fi
fi

rm -f "$MOCK_CWD/tmp/arc-result-current.json"

# ═══════════════════════════════════════════════════════════════
# 4. Merge completed → signal written
# ═══════════════════════════════════════════════════════════════
printf "\n=== Merge Completed ===\n"

cat > "$CKPT_FILE" <<JSON
{
  "id": "test-arc-1",
  "plan_file": "plans/test.md",
  "owner_pid": "$PPID",
  "config_dir": "/tmp/test",
  "phases": {
    "ship": {"status": "completed"},
    "merge": {"status": "completed"}
  }
}
JSON

INPUT=$(jq -n --arg fp "$CKPT_FILE" --arg cwd "$MOCK_CWD" \
  '{tool_input: {file_path: $fp}, cwd: $cwd}')

echo "$INPUT" | bash "$UNDER_TEST" >/dev/null 2>&1

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$MOCK_CWD/tmp/arc-result-current.json" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Signal created on merge completion\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Signal NOT created on merge completion\n"
fi

rm -f "$MOCK_CWD/tmp/arc-result-current.json"

# ═══════════════════════════════════════════════════════════════
# 5. Failed phases → status "partial"
# ═══════════════════════════════════════════════════════════════
printf "\n=== Failed Phases ===\n"

cat > "$CKPT_FILE" <<JSON
{
  "id": "test-arc-1",
  "plan_file": "plans/test.md",
  "owner_pid": "$PPID",
  "config_dir": "/tmp/test",
  "phases": {
    "forge": {"status": "completed"},
    "work": {"status": "failed"},
    "ship": {"status": "completed"},
    "merge": {"status": "pending"}
  }
}
JSON

INPUT=$(jq -n --arg fp "$CKPT_FILE" --arg cwd "$MOCK_CWD" \
  '{tool_input: {file_path: $fp}, cwd: $cwd}')

echo "$INPUT" | bash "$UNDER_TEST" >/dev/null 2>&1

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$MOCK_CWD/tmp/arc-result-current.json" ]]; then
  signal_status=$(python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("status",""))' < "$MOCK_CWD/tmp/arc-result-current.json" 2>/dev/null || echo "")
  if [[ "$signal_status" == "partial" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: Signal status is 'partial' when phases failed\n"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: Signal status is '%s' (expected 'partial')\n" "$signal_status"
  fi
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Signal not created\n"
fi

rm -f "$MOCK_CWD/tmp/arc-result-current.json"

# ═══════════════════════════════════════════════════════════════
# 6. Non-arc checkpoint path → no signal
# ═══════════════════════════════════════════════════════════════
printf "\n=== Non-arc Path ===\n"

NON_ARC_FILE="$MOCK_CWD/some/other/checkpoint.json"
mkdir -p "$(dirname "$NON_ARC_FILE")"
echo '{"phases":{"ship":{"status":"completed"}}}' > "$NON_ARC_FILE"

INPUT=$(jq -n --arg fp "$NON_ARC_FILE" --arg cwd "$MOCK_CWD" \
  '{tool_input: {file_path: $fp}, cwd: $cwd}')

echo "$INPUT" | bash "$UNDER_TEST" >/dev/null 2>&1

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ ! -f "$MOCK_CWD/tmp/arc-result-current.json" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Non-arc path produces no signal\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Non-arc path produced a signal\n"
  rm -f "$MOCK_CWD/tmp/arc-result-current.json"
fi

# ═══════════════════════════════════════════════════════════════
# 7. Signal has schema_version
# ═══════════════════════════════════════════════════════════════
printf "\n=== Schema Version ===\n"

cat > "$CKPT_FILE" <<JSON
{
  "id": "test-arc-sv",
  "plan_file": "plans/test.md",
  "owner_pid": "$PPID",
  "config_dir": "/tmp/test",
  "phases": {"ship": {"status": "completed"}}
}
JSON

INPUT=$(jq -n --arg fp "$CKPT_FILE" --arg cwd "$MOCK_CWD" \
  '{tool_input: {file_path: $fp}, cwd: $cwd}')

echo "$INPUT" | bash "$UNDER_TEST" >/dev/null 2>&1

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$MOCK_CWD/tmp/arc-result-current.json" ]]; then
  sv=$(python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("schema_version",""))' < "$MOCK_CWD/tmp/arc-result-current.json" 2>/dev/null || echo "")
  if [[ "$sv" == "1" ]]; then
    PASS_COUNT=$(( PASS_COUNT + 1 ))
    printf "  PASS: Signal has schema_version=1\n"
  else
    FAIL_COUNT=$(( FAIL_COUNT + 1 ))
    printf "  FAIL: schema_version='%s'\n" "$sv"
  fi
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Signal not created\n"
fi

rm -f "$MOCK_CWD/tmp/arc-result-current.json"

# ═══════════════════════════════════════════════════════════════
# 8. Symlink checkpoint → no signal
# ═══════════════════════════════════════════════════════════════
printf "\n=== Symlink Checkpoint ===\n"

rm -f "$CKPT_FILE"
echo '{"phases":{"ship":{"status":"completed"}}}' > "$TMP_DIR/real-ckpt.json"
ln -sf "$TMP_DIR/real-ckpt.json" "$CKPT_FILE"

INPUT=$(jq -n --arg fp "$CKPT_FILE" --arg cwd "$MOCK_CWD" \
  '{tool_input: {file_path: $fp}, cwd: $cwd}')

echo "$INPUT" | bash "$UNDER_TEST" >/dev/null 2>&1

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ ! -f "$MOCK_CWD/tmp/arc-result-current.json" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Symlink checkpoint produces no signal\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Symlink checkpoint produced a signal\n"
  rm -f "$MOCK_CWD/tmp/arc-result-current.json"
fi

# ═══════════════════════════════════════════════════════════════
# 9. Always exits 0
# ═══════════════════════════════════════════════════════════════
printf "\n=== Always Exit 0 ===\n"

result_code=0
echo '{}' | bash "$UNDER_TEST" >/dev/null 2>&1 || result_code=$?
assert_eq "Empty input → exit 0" "0" "$result_code"

result_code=0
echo 'not-json' | bash "$UNDER_TEST" >/dev/null 2>&1 || result_code=$?
assert_eq "Invalid JSON → exit 0" "0" "$result_code"

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
