#!/usr/bin/env bash
# test-stop-hook-persistence.sh — Tests for stop hook persistence check logic
#
# Usage: bash plugins/rune/scripts/tests/test-stop-hook-persistence.sh
# Exit: 0 on all pass, 1 on any failure.
#
# Tests the persistence retry logic added to arc-phase-stop-hook.sh (v2.31.0).
# Uses mock checkpoint JSON and talisman shard to validate decision paths.

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

# ── Setup ──
TEST_DIR="${TMPDIR:-/tmp}/rune-test-persist-$$"
mkdir -p "$TEST_DIR/tmp/.talisman-resolved"
trap 'rm -rf "$TEST_DIR"' EXIT

# Helper: create a mock checkpoint
_make_checkpoint() {
  local phase_name="$1"
  local phase_status="$2"
  local retries="${3:-0}"
  local cost="${4:-0}"
  local verified="${5:-false}"
  cat <<EOF
{
  "schema_version": 28,
  "stop_hook_retries": $retries,
  "cumulative_retry_cost_cents": $cost,
  "work_completion_verified": $verified,
  "phases": {
    "$phase_name": {
      "status": "$phase_status",
      "started_at": "2026-03-30T05:00:00Z",
      "completed_at": null
    }
  }
}
EOF
}

# Helper: create a mock talisman arc shard
_make_arc_shard() {
  local enabled="${1:-false}"
  local max_retries="${2:-3}"
  local max_budget="${3:-500}"
  cat <<EOF
{
  "persistence": {
    "enabled": $enabled,
    "max_retries": $max_retries,
    "max_budget_cents": $max_budget
  },
  "heartbeat": {
    "stale_threshold_minutes": 15
  },
  "skip_phases": []
}
EOF
}

# Helper: simulate the persistence decision logic (extracted from stop hook)
# Returns: "retry" | "exhausted" | "skip" (disabled/not-failed)
_check_persistence() {
  local ckpt="$1"
  local shard_path="$2"
  local prev_phase="$3"

  local prev_status
  prev_status=$(echo "$ckpt" | jq -r ".phases.${prev_phase}.status // \"pending\"" 2>/dev/null || echo "pending")

  if [[ "$prev_status" != "failed" ]]; then
    echo "skip:not_failed"
    return 0
  fi

  local persist_enabled="false"
  local persist_max_retries=3
  local persist_max_budget=500

  if [[ -n "$shard_path" && -f "$shard_path" ]]; then
    persist_enabled=$(jq -r '.persistence.enabled // false' "$shard_path" 2>/dev/null || echo "false")
    persist_max_retries=$(jq -r '.persistence.max_retries // 3' "$shard_path" 2>/dev/null || echo "3")
    persist_max_budget=$(jq -r '.persistence.max_budget_cents // 500' "$shard_path" 2>/dev/null || echo "500")
  fi

  # Validate numeric
  [[ "$persist_max_retries" =~ ^[0-9]+$ ]] || persist_max_retries=3
  [[ "$persist_max_budget" =~ ^[0-9]+$ ]] || persist_max_budget=500

  if [[ "$persist_enabled" != "true" ]]; then
    echo "skip:disabled"
    return 0
  fi

  local current_retries
  local current_cost
  current_retries=$(echo "$ckpt" | jq -r '.stop_hook_retries // 0' 2>/dev/null || echo "0")
  current_cost=$(echo "$ckpt" | jq -r '.cumulative_retry_cost_cents // 0' 2>/dev/null || echo "0")
  [[ "$current_retries" =~ ^[0-9]+$ ]] || current_retries=0
  [[ "$current_cost" =~ ^[0-9]+$ ]] || current_cost=0

  if [[ "$current_retries" -lt "$persist_max_retries" && "$current_cost" -lt "$persist_max_budget" ]]; then
    echo "retry:${current_retries}/${persist_max_retries},${current_cost}c/${persist_max_budget}c"
    return 0
  fi

  echo "exhausted:retries=${current_retries},cost=${current_cost}"
  return 0
}

# ══════════════════════════════════════════════════════
printf "\n=== Persistence: Disabled (exits normally) ===\n"
# ══════════════════════════════════════════════════════

shard_path="$TEST_DIR/tmp/.talisman-resolved/arc.json"
_make_arc_shard false 3 500 > "$shard_path"
ckpt=$(_make_checkpoint "work" "failed" 0 0)
result=$(_check_persistence "$ckpt" "$shard_path" "work")
assert_eq "disabled persistence → skip" "skip:disabled" "$result"

# ══════════════════════════════════════════════════════
printf "\n=== Persistence: Enabled + Phase Not Failed ===\n"
# ══════════════════════════════════════════════════════

_make_arc_shard true 3 500 > "$shard_path"
ckpt=$(_make_checkpoint "work" "completed" 0 0)
result=$(_check_persistence "$ckpt" "$shard_path" "work")
assert_eq "completed phase → skip (not failed)" "skip:not_failed" "$result"

# ══════════════════════════════════════════════════════
printf "\n=== Persistence: Enabled + Failed + Retries=0 → Retry ===\n"
# ══════════════════════════════════════════════════════

ckpt=$(_make_checkpoint "work" "failed" 0 0)
result=$(_check_persistence "$ckpt" "$shard_path" "work")
assert_eq "first retry attempt" "retry:0/3,0c/500c" "$result"

# ══════════════════════════════════════════════════════
printf "\n=== Persistence: Retries Exhausted → Advance ===\n"
# ══════════════════════════════════════════════════════

ckpt=$(_make_checkpoint "work" "failed" 3 100)
result=$(_check_persistence "$ckpt" "$shard_path" "work")
assert_eq "retries=max → exhausted" "exhausted:retries=3,cost=100" "$result"

# ══════════════════════════════════════════════════════
printf "\n=== Persistence: Budget Exceeded → Advance ===\n"
# ══════════════════════════════════════════════════════

ckpt=$(_make_checkpoint "work" "failed" 1 600)
result=$(_check_persistence "$ckpt" "$shard_path" "work")
assert_eq "cost over budget → exhausted" "exhausted:retries=1,cost=600" "$result"

# ══════════════════════════════════════════════════════
printf "\n=== Persistence: Partial Budget (under limit) → Retry ===\n"
# ══════════════════════════════════════════════════════

ckpt=$(_make_checkpoint "work" "failed" 1 200)
result=$(_check_persistence "$ckpt" "$shard_path" "work")
assert_eq "under budget + under retries → retry" "retry:1/3,200c/500c" "$result"

# ══════════════════════════════════════════════════════
printf "\n=== Persistence: Custom Limits from Shard ===\n"
# ══════════════════════════════════════════════════════

_make_arc_shard true 5 1000 > "$shard_path"
ckpt=$(_make_checkpoint "code_review" "failed" 4 900)
result=$(_check_persistence "$ckpt" "$shard_path" "code_review")
assert_eq "custom limits: 4/5 retries, 900/1000 → retry" "retry:4/5,900c/1000c" "$result"

ckpt=$(_make_checkpoint "code_review" "failed" 5 900)
result=$(_check_persistence "$ckpt" "$shard_path" "code_review")
assert_eq "custom limits: 5/5 retries → exhausted" "exhausted:retries=5,cost=900" "$result"

# ══════════════════════════════════════════════════════
printf "\n=== Persistence: Invalid/Missing Shard → Graceful Skip ===\n"
# ══════════════════════════════════════════════════════

ckpt=$(_make_checkpoint "work" "failed" 0 0)
result=$(_check_persistence "$ckpt" "/nonexistent/arc.json" "work")
assert_eq "missing shard → skip (disabled)" "skip:disabled" "$result"

result=$(_check_persistence "$ckpt" "" "work")
assert_eq "empty shard path → skip (disabled)" "skip:disabled" "$result"

# ══════════════════════════════════════════════════════
printf "\n=== Persistence: Invalid Checkpoint JSON → Graceful Defaults ===\n"
# ══════════════════════════════════════════════════════

_make_arc_shard true 3 500 > "$shard_path"
invalid_ckpt='{"phases":{"work":{"status":"failed"}}}'
result=$(_check_persistence "$invalid_ckpt" "$shard_path" "work")
assert_eq "missing retry fields → defaults to 0/0 → retry" "retry:0/3,0c/500c" "$result"

# ══════════════════════════════════════════════════════
printf "\n=== Persistence: Non-numeric Shard Values → Safe Defaults ===\n"
# ══════════════════════════════════════════════════════

# Write shard with non-numeric values to test SEC validation guard
cat > "$shard_path" << 'BADEOF'
{
  "persistence": {
    "enabled": true,
    "max_retries": "not_a_number",
    "max_budget_cents": "also_bad"
  }
}
BADEOF
ckpt=$(_make_checkpoint "work" "failed" 0 0)
result=$(_check_persistence "$ckpt" "$shard_path" "work")
assert_eq "non-numeric shard values → falls back to defaults 3/500 → retry" "retry:0/3,0c/500c" "$result"

# ══════════════════════════════════════════════════════
printf "\n=== Results ===\n"
# ══════════════════════════════════════════════════════

printf "Total: %d  Passed: %d  Failed: %d\n" "$TOTAL_COUNT" "$PASS_COUNT" "$FAIL_COUNT"

if [[ "$FAIL_COUNT" -gt 0 ]]; then
  exit 1
fi
exit 0
