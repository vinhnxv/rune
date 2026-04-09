#!/usr/bin/env bash
# test-rune-statusline.sh -- Tests for scripts/rune-statusline.sh
#
# Usage: bash plugins/rune/scripts/tests/test-rune-statusline.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail
umask 077

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STATUSLINE="${SCRIPT_DIR}/../rune-statusline.sh"

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
    printf "  FAIL: %s (needle found but should not be)\n" "$test_name"
    printf "    needle:   %q\n" "$needle"
    printf "    haystack: %q\n" "$haystack"
  fi
}

TMPROOT=$(mktemp -d)
trap 'rm -rf "$TMPROOT"' EXIT

# Create a fake workspace directory (statusline reads DIR for git + workflow detection)
FAKE_DIR="${TMPROOT}/workspace"
mkdir -p "$FAKE_DIR/tmp"

# Helper: build valid statusline input JSON
mk_input() {
  local model="${1:-Claude}" dir="${2:-$FAKE_DIR}" sid="${3:-test-session-id}" remaining="${4:-75}" used="${5:-25}" cost="${6:-0.50}" worktree="${7:-}"
  if [[ -n "$worktree" ]]; then
    printf '{"model":{"display_name":"%s"},"workspace":{"current_dir":"%s","git_worktree":"%s"},"session_id":"%s","context_window":{"remaining_percentage":%s,"used_percentage":%s},"cost":{"total_cost_usd":%s}}' \
      "$model" "$dir" "$worktree" "$sid" "$remaining" "$used" "$cost"
  else
    printf '{"model":{"display_name":"%s"},"workspace":{"current_dir":"%s"},"session_id":"%s","context_window":{"remaining_percentage":%s,"used_percentage":%s},"cost":{"total_cost_usd":%s}}' \
      "$model" "$dir" "$sid" "$remaining" "$used" "$cost"
  fi
}

# ===================================================================
# 1. Basic output with model name
# ===================================================================
printf "\n=== Basic output with model name ===\n"

output=$(mk_input "Opus" "$FAKE_DIR" "sid1" 80 20 0.25 | bash "$STATUSLINE" 2>/dev/null)
# Strip ANSI codes for content check
clean=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "Model name in output" "Opus" "$clean"

# ===================================================================
# 2. Used percentage in output
# ===================================================================
printf "\n=== Used percentage ===\n"

output=$(mk_input "Claude" "$FAKE_DIR" "sid2" 55 45 1.00 | bash "$STATUSLINE" 2>/dev/null)
clean=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "Used percentage displayed" "45%" "$clean"

# ===================================================================
# 3. Cost formatting
# ===================================================================
printf "\n=== Cost formatting ===\n"

output=$(mk_input "Claude" "$FAKE_DIR" "sid3" 60 40 3.75 | bash "$STATUSLINE" 2>/dev/null)
clean=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "Cost formatted" '$3.75' "$clean"

# ===================================================================
# 4. Zero cost
# ===================================================================
printf "\n=== Zero cost ===\n"

output=$(mk_input "Claude" "$FAKE_DIR" "sid4" 95 5 0 | bash "$STATUSLINE" 2>/dev/null)
clean=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "Zero cost displayed" '$0.00' "$clean"

# ===================================================================
# 5. Progress bar present
# ===================================================================
printf "\n=== Progress bar ===\n"

output=$(mk_input "Claude" "$FAKE_DIR" "sid5" 50 50 0.10 | bash "$STATUSLINE" 2>/dev/null)
# Check for block characters (unicode progress bar)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if printf '%s' "$output" | grep -q '[█░]' 2>/dev/null; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Progress bar characters present\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: No progress bar characters found\n"
fi

# ===================================================================
# 6. Bridge file written for valid session
# ===================================================================
printf "\n=== Bridge file written ===\n"

BRIDGE_SID="test-bridge-sid"
BRIDGE_FILE="${TMPDIR:-/tmp}/rune-ctx-${BRIDGE_SID}.json"
rm -f "$BRIDGE_FILE" 2>/dev/null

mk_input "Claude" "$FAKE_DIR" "$BRIDGE_SID" 70 30 0.50 | bash "$STATUSLINE" >/dev/null 2>&1

TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$BRIDGE_FILE" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Bridge file created\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Bridge file not created at %s\n" "$BRIDGE_FILE"
fi

# ===================================================================
# 7. Bridge file contains valid JSON with required fields
# ===================================================================
printf "\n=== Bridge file JSON structure ===\n"

if [[ -f "$BRIDGE_FILE" ]]; then
  bridge_valid=$(python3 -c "
import json, sys
d = json.load(open('$BRIDGE_FILE'))
assert 'session_id' in d
assert 'remaining_percentage' in d
assert 'used_pct' in d
assert 'timestamp' in d
assert 'config_dir' in d
assert 'owner_pid' in d
print('ok')
" 2>/dev/null || echo "fail")
  assert_eq "Bridge JSON has required fields" "ok" "$bridge_valid"
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Bridge file missing for JSON check\n"
fi

# Clean up bridge file
rm -f "$BRIDGE_FILE" 2>/dev/null

# ===================================================================
# 8. Exit code is always 0 (fail-open)
# ===================================================================
printf "\n=== Fail-open exit code ===\n"

rc=0
echo '{}' | bash "$STATUSLINE" >/dev/null 2>&1 || rc=$?
assert_eq "Malformed input exits 0" "0" "$rc"

rc=0
echo '' | bash "$STATUSLINE" >/dev/null 2>&1 || rc=$?
assert_eq "Empty input exits 0" "0" "$rc"

# ===================================================================
# 9. High usage (>=90%) shows blinking red
# ===================================================================
printf "\n=== High usage color ===\n"

output=$(mk_input "Claude" "$FAKE_DIR" "sid-high" 5 95 5.00 | bash "$STATUSLINE" 2>/dev/null)
# Check for ANSI blink code (\033[5;31m)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if printf '%s' "$output" | grep -q $'\033\[5;31m' 2>/dev/null; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Blinking red for 95%% usage\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: No blinking red for 95%% usage\n"
fi

# ===================================================================
# 10. Low usage (<50%) shows green
# ===================================================================
printf "\n=== Low usage color ===\n"

output=$(mk_input "Claude" "$FAKE_DIR" "sid-low" 80 20 0.10 | bash "$STATUSLINE" 2>/dev/null)
# Check for green ANSI code (\033[32m)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if printf '%s' "$output" | grep -q $'\033\[32m' 2>/dev/null; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Green for 20%% usage\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: No green for 20%% usage\n"
fi

# ===================================================================
# 11. Session ID with special chars doesn't write bridge file
# ===================================================================
printf "\n=== Invalid session_id no bridge ===\n"

BAD_SID="../evil-path"
mk_input "Claude" "$FAKE_DIR" "$BAD_SID" 70 30 0.50 | bash "$STATUSLINE" >/dev/null 2>&1
# Should not create a bridge file for invalid session_id
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ ! -f "${TMPDIR:-/tmp}/rune-ctx-${BAD_SID}.json" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: No bridge file for invalid session_id\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Bridge file created for invalid session_id\n"
  rm -f "${TMPDIR:-/tmp}/rune-ctx-${BAD_SID}.json" 2>/dev/null
fi

# ===================================================================
# 12. Active workflow displayed
# ===================================================================
printf "\n=== Active workflow display ===\n"

WF_DIR="${TMPROOT}/wf-workspace"
mkdir -p "$WF_DIR/tmp"
cat > "$WF_DIR/tmp/.rune-review.json" <<'EOF'
{"status":"active","workflow":"review"}
EOF

output=$(mk_input "Claude" "$WF_DIR" "sid-wf" 60 40 0.50 | bash "$STATUSLINE" 2>/dev/null)
clean=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "Active workflow shown" "review" "$clean"

# ===================================================================
# 13. No workflow for completed status
# ===================================================================
printf "\n=== Completed workflow not shown ===\n"

DONE_DIR="${TMPROOT}/done-workspace"
mkdir -p "$DONE_DIR/tmp"
cat > "$DONE_DIR/tmp/.rune-audit.json" <<'EOF'
{"status":"completed","workflow":"audit"}
EOF

output=$(mk_input "Claude" "$DONE_DIR" "sid-done" 60 40 0.50 | bash "$STATUSLINE" 2>/dev/null)
clean=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
assert_not_contains "Completed workflow not shown" "audit" "$clean"

# ===================================================================
# 14. Trace logging
# ===================================================================
printf "\n=== Trace logging ===\n"

TRACE_LOG="${TMPROOT}/trace.log"
rm -f "$TRACE_LOG" 2>/dev/null

mk_input "Claude" "$FAKE_DIR" "sid-trace" 70 30 0.50 | \
  RUNE_TRACE=1 RUNE_TRACE_LOG="$TRACE_LOG" bash "$STATUSLINE" >/dev/null 2>&1

if [[ -f "$TRACE_LOG" ]]; then
  trace_content=$(cat "$TRACE_LOG")
  assert_contains "Trace log mentions PARSED" "PARSED" "$trace_content"
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Trace log not created\n"
fi

# ===================================================================
# 15. Medium usage (65-80%) shows orange
# ===================================================================
printf "\n=== Medium usage color ===\n"

output=$(mk_input "Claude" "$FAKE_DIR" "sid-med" 30 70 2.00 | bash "$STATUSLINE" 2>/dev/null)
# Check for orange ANSI code (\033[38;5;208m)
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if printf '%s' "$output" | grep -q $'\033\[38;5;208m' 2>/dev/null; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Orange for 70%% usage\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: No orange for 70%% usage\n"
fi

# ===================================================================
# 16. Worktree indicator shown when git_worktree is present
# ===================================================================
printf "\n=== Worktree indicator shown ===\n"

# Create a fake git repo so BRANCH is populated
WT_DIR="${TMPROOT}/wt-workspace"
mkdir -p "$WT_DIR/tmp"
git -C "$WT_DIR" init -q 2>/dev/null
git -C "$WT_DIR" checkout -q -b feat-auth 2>/dev/null || true

output=$(mk_input "Claude" "$WT_DIR" "sid-wt" 60 40 0.50 "/tmp/worktrees/feat-auth" | bash "$STATUSLINE" 2>/dev/null)
clean=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
assert_contains "Worktree indicator present" "wt" "$clean"

# ===================================================================
# 17. No worktree indicator when git_worktree is absent
# ===================================================================
printf "\n=== No worktree indicator when absent ===\n"

output=$(mk_input "Claude" "$WT_DIR" "sid-nowt" 60 40 0.50 | bash "$STATUSLINE" 2>/dev/null)
clean=$(printf '%s' "$output" | sed 's/\x1b\[[0-9;]*m//g')
assert_not_contains "No worktree indicator" "wt" "$clean"

# ===================================================================
# 18. Bridge file includes is_worktree field
# ===================================================================
printf "\n=== Bridge file is_worktree field ===\n"

WT_BRIDGE_SID="test-wt-bridge"
WT_BRIDGE_FILE="${TMPDIR:-/tmp}/rune-ctx-${WT_BRIDGE_SID}.json"
rm -f "$WT_BRIDGE_FILE" 2>/dev/null

mk_input "Claude" "$WT_DIR" "$WT_BRIDGE_SID" 70 30 0.50 "/tmp/worktrees/feat-auth" | bash "$STATUSLINE" >/dev/null 2>&1

if [[ -f "$WT_BRIDGE_FILE" ]]; then
  wt_val=$(python3 -c "
import json, sys
d = json.load(open('$WT_BRIDGE_FILE'))
assert d.get('is_worktree') == True, f'is_worktree={d.get(\"is_worktree\")}'
print('ok')
" 2>/dev/null || echo "fail")
  assert_eq "Bridge is_worktree=true for worktree session" "ok" "$wt_val"
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Bridge file missing for worktree check\n"
fi
rm -f "$WT_BRIDGE_FILE" 2>/dev/null

# ===================================================================
# 19. Bridge file is_worktree=false when not in worktree
# ===================================================================
printf "\n=== Bridge file is_worktree=false when absent ===\n"

NOWT_BRIDGE_SID="test-nowt-bridge"
NOWT_BRIDGE_FILE="${TMPDIR:-/tmp}/rune-ctx-${NOWT_BRIDGE_SID}.json"
rm -f "$NOWT_BRIDGE_FILE" 2>/dev/null

mk_input "Claude" "$FAKE_DIR" "$NOWT_BRIDGE_SID" 70 30 0.50 | bash "$STATUSLINE" >/dev/null 2>&1

if [[ -f "$NOWT_BRIDGE_FILE" ]]; then
  nowt_val=$(python3 -c "
import json, sys
d = json.load(open('$NOWT_BRIDGE_FILE'))
assert d.get('is_worktree') == False, f'is_worktree={d.get(\"is_worktree\")}'
print('ok')
" 2>/dev/null || echo "fail")
  assert_eq "Bridge is_worktree=false for normal session" "ok" "$nowt_val"
else
  TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Bridge file missing for non-worktree check\n"
fi
rm -f "$NOWT_BRIDGE_FILE" 2>/dev/null

# ===================================================================
# Results
# ===================================================================
printf "\n===================================================\n"
printf "Results: %d/%d passed, %d failed\n" "$PASS_COUNT" "$TOTAL_COUNT" "$FAIL_COUNT"
printf "===================================================\n"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
