#!/usr/bin/env bash
# test-stop-failure-common.sh — Tests for scripts/lib/stop-failure-common.sh
#
# Usage: bash plugins/rune/scripts/tests/test-stop-failure-common.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"

# ── Test framework ──
PASS_COUNT=0
FAIL_COUNT=0
TOTAL_COUNT=0

assert_eq() {
  local test_name="$1"
  local expected="$2"
  local actual="$3"
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

# ── Setup: mock dependencies ──
# stop-failure-common.sh depends on INPUT, CWD, and optionally _rune_detect_rate_limit
CWD="${TMPDIR:-/tmp}/rune-test-sf-$$"
mkdir -p "$CWD/tmp"
trap 'rm -rf "$CWD"' EXIT

# Mock _rune_resolve_talisman_shard to return nonexistent path (skip talisman)
_rune_resolve_talisman_shard() { echo "/nonexistent"; }
export -f _rune_resolve_talisman_shard 2>/dev/null || true

# ── Helper: run classification with a given INPUT ──
_classify() {
  local input="$1"
  # Reset source guard so we can re-source
  unset _RUNE_STOP_FAILURE_COMMON_LOADED
  INPUT="$input"
  source "${LIB_DIR}/stop-failure-common.sh"
  classify_stop_failure
  printf '%s|%s|%s' "$ERROR_TYPE" "$WAIT_SECONDS" "$ERROR_ACTION"
}

# ══════════════════════════════════════════════════════
printf "\n=== classify_stop_failure: Rate Limit Detection ===\n"
# ══════════════════════════════════════════════════════

result=$(_classify '{"error": "429 Too Many Requests", "error_message": "", "stop_reason": ""}')
assert_eq "429 in error field → RATE_LIMIT" "RATE_LIMIT" "$(echo "$result" | cut -d'|' -f1)"

result=$(_classify '{"error": "rate limit exceeded", "error_message": "", "stop_reason": ""}')
assert_eq "rate limit text → RATE_LIMIT" "RATE_LIMIT" "$(echo "$result" | cut -d'|' -f1)"

result=$(_classify '{"error": "overloaded_error", "error_message": "", "stop_reason": ""}')
assert_eq "overloaded_error → RATE_LIMIT" "RATE_LIMIT" "$(echo "$result" | cut -d'|' -f1)"

result=$(_classify '{"error": "too many requests", "error_message": "", "stop_reason": ""}')
assert_eq "too many requests → RATE_LIMIT" "RATE_LIMIT" "$(echo "$result" | cut -d'|' -f1)"

result=$(_classify '{"error": "retry-after: 120", "error_message": "", "stop_reason": ""}')
assert_eq "retry-after with value → RATE_LIMIT" "RATE_LIMIT" "$(echo "$result" | cut -d'|' -f1)"
assert_eq "retry-after extracts wait seconds" "120" "$(echo "$result" | cut -d'|' -f2)"

# ══════════════════════════════════════════════════════
printf "\n=== classify_stop_failure: Auth Detection ===\n"
# ══════════════════════════════════════════════════════

result=$(_classify '{"error": "401 Unauthorized", "error_message": "", "stop_reason": ""}')
assert_eq "401 → AUTH" "AUTH" "$(echo "$result" | cut -d'|' -f1)"
assert_eq "AUTH → halt action" "halt" "$(echo "$result" | cut -d'|' -f3)"

result=$(_classify '{"error": "403 Forbidden", "error_message": "", "stop_reason": ""}')
assert_eq "403 → AUTH" "AUTH" "$(echo "$result" | cut -d'|' -f1)"

result=$(_classify '{"error": "authentication failed", "error_message": "", "stop_reason": ""}')
assert_eq "auth fail text → AUTH" "AUTH" "$(echo "$result" | cut -d'|' -f1)"

result=$(_classify '{"error": "token expired", "error_message": "", "stop_reason": ""}')
assert_eq "token expired → AUTH" "AUTH" "$(echo "$result" | cut -d'|' -f1)"

result=$(_classify '{"error": "permission denied", "error_message": "", "stop_reason": ""}')
assert_eq "permission denied → AUTH" "AUTH" "$(echo "$result" | cut -d'|' -f1)"

# ══════════════════════════════════════════════════════
printf "\n=== classify_stop_failure: Server Error Detection ===\n"
# ══════════════════════════════════════════════════════

result=$(_classify '{"error": "500 Internal Server Error", "error_message": "", "stop_reason": ""}')
assert_eq "500 → SERVER" "SERVER" "$(echo "$result" | cut -d'|' -f1)"
assert_eq "SERVER → backoff action" "backoff" "$(echo "$result" | cut -d'|' -f3)"

result=$(_classify '{"error": "502 Bad Gateway", "error_message": "", "stop_reason": ""}')
assert_eq "502 → SERVER" "SERVER" "$(echo "$result" | cut -d'|' -f1)"

result=$(_classify '{"error": "503 Service Unavailable", "error_message": "", "stop_reason": ""}')
assert_eq "503 → SERVER" "SERVER" "$(echo "$result" | cut -d'|' -f1)"

result=$(_classify '{"error": "504 Gateway Timeout", "error_message": "", "stop_reason": ""}')
assert_eq "504 → SERVER" "SERVER" "$(echo "$result" | cut -d'|' -f1)"

result=$(_classify '{"error": "internal error occurred", "error_message": "", "stop_reason": ""}')
assert_eq "internal error text → SERVER" "SERVER" "$(echo "$result" | cut -d'|' -f1)"

result=$(_classify '{"error": "service unavailable", "error_message": "", "stop_reason": ""}')
assert_eq "service unavailable text → SERVER" "SERVER" "$(echo "$result" | cut -d'|' -f1)"

# ══════════════════════════════════════════════════════
printf "\n=== classify_stop_failure: Unknown/Fallback ===\n"
# ══════════════════════════════════════════════════════

result=$(_classify '{"error": "something unexpected happened", "error_message": "", "stop_reason": ""}')
assert_eq "unrecognized error → UNKNOWN" "UNKNOWN" "$(echo "$result" | cut -d'|' -f1)"
assert_eq "UNKNOWN → proceed action" "proceed" "$(echo "$result" | cut -d'|' -f3)"

result=$(_classify '{}')
assert_eq "empty JSON → UNKNOWN" "UNKNOWN" "$(echo "$result" | cut -d'|' -f1)"

# ══════════════════════════════════════════════════════
printf "\n=== classify_stop_failure: Word Boundary (no false positives) ===\n"
# ══════════════════════════════════════════════════════

result=$(_classify '{"error": "port 4290 connection refused", "error_message": "", "stop_reason": ""}')
assert_eq "4290 should NOT match 429" "UNKNOWN" "$(echo "$result" | cut -d'|' -f1)"

result=$(_classify '{"error": "error code 4013", "error_message": "", "stop_reason": ""}')
assert_eq "4013 should NOT match 401" "UNKNOWN" "$(echo "$result" | cut -d'|' -f1)"

result=$(_classify '{"error": "listening on port 5000", "error_message": "", "stop_reason": ""}')
assert_eq "5000 should NOT match 500" "UNKNOWN" "$(echo "$result" | cut -d'|' -f1)"

# ══════════════════════════════════════════════════════
printf "\n=== classify_stop_failure: Multi-field Detection ===\n"
# ══════════════════════════════════════════════════════

result=$(_classify '{"error": "", "error_message": "rate limited", "stop_reason": ""}')
assert_eq "rate limit in error_message → RATE_LIMIT" "RATE_LIMIT" "$(echo "$result" | cut -d'|' -f1)"

result=$(_classify '{"error": "", "error_message": "", "stop_reason": "401 auth failure"}')
assert_eq "auth in stop_reason → AUTH" "AUTH" "$(echo "$result" | cut -d'|' -f1)"

# ══════════════════════════════════════════════════════
printf "\n=== Results ===\n"
# ══════════════════════════════════════════════════════

printf "\n%d/%d tests passed" "$PASS_COUNT" "$TOTAL_COUNT"
if [[ "$FAIL_COUNT" -gt 0 ]]; then
  printf " (%d FAILED)\n" "$FAIL_COUNT"
  exit 1
else
  printf "\n"
  exit 0
fi
