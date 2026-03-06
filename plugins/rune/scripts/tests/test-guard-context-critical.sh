#!/usr/bin/env bash
# test-guard-context-critical.sh — Tests for scripts/guard-context-critical.sh
#
# Usage: bash plugins/rune/scripts/tests/test-guard-context-critical.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
UNDER_TEST="$SCRIPTS_DIR/guard-context-critical.sh"

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

MOCK_CHOME="$TMP_DIR/claude-config"
mkdir -p "$MOCK_CHOME"

# Resolve paths (macOS: /tmp → /private/tmp symlink)
MOCK_CWD=$(cd "$MOCK_CWD" && pwd -P)
MOCK_CHOME=$(cd "$MOCK_CHOME" && pwd -P)

SESSION_ID="test-guard-session-$$"

# Helper: create bridge file with given remaining_percentage
# NOTE: owner_pid is set to "NONE" (non-numeric) to bypass the script's PID ownership
# check. The script checks [[ "$BRIDGE_PID" =~ ^[0-9]+$ ]] — non-numeric values skip
# the whole block. We can't omit owner_pid because bash read with IFS=$'\t' treats
# consecutive tabs as one delimiter, shifting remaining fields left.
create_bridge() {
  local rem_pct="$1"
  local bridge_file="/tmp/rune-ctx-${SESSION_ID}.json"
  jq -n \
    --arg sid "$SESSION_ID" \
    --argjson rem "$rem_pct" \
    --argjson used "$((100 - rem_pct))" \
    --argjson ts "$(date +%s)" \
    --arg cfg "$MOCK_CHOME" \
    --arg pid "NONE" \
    '{session_id: $sid, remaining_percentage: $rem, used_pct: $used, timestamp: $ts, config_dir: $cfg, owner_pid: $pid}' \
    > "$bridge_file"
}

cleanup_bridge() {
  rm -f "/tmp/rune-ctx-${SESSION_ID}.json"
  rm -f "$MOCK_CWD/tmp/.rune-shutdown-signal-${SESSION_ID}.json"
  rm -f "$MOCK_CWD/tmp/.rune-force-shutdown-${SESSION_ID}.json"
}

# ═══════════════════════════════════════════════════════════════
# 1. Empty input → exit 0
# ═══════════════════════════════════════════════════════════════
printf "\n=== Empty Input ===\n"

result_code=0
echo '' | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" >/dev/null 2>&1 || result_code=$?
assert_eq "Empty input → exit 0" "0" "$result_code"

# ═══════════════════════════════════════════════════════════════
# 2. No bridge file → exit 0 (allow)
# ═══════════════════════════════════════════════════════════════
printf "\n=== No Bridge File ===\n"

cleanup_bridge
# NOTE: tool_input.subagent_type must be non-empty for bash read -r with IFS=$'\t'
# to correctly split all 4 fields (bash treats consecutive tabs as one delimiter).
INPUT=$(jq -n \
  --arg tool "TeamCreate" \
  --arg cwd "$MOCK_CWD" \
  --arg sid "$SESSION_ID" \
  '{tool_name: $tool, tool_input: {subagent_type: "general-purpose"}, cwd: $cwd, session_id: $sid}')

result_code=0
result=$(echo "$INPUT" | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null) || result_code=$?
assert_eq "No bridge → exit 0 (allow)" "0" "$result_code"

# ═══════════════════════════════════════════════════════════════
# 3. Healthy context (60% remaining) → exit 0
# ═══════════════════════════════════════════════════════════════
printf "\n=== Healthy Context ===\n"

create_bridge 60
result=$(echo "$INPUT" | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_eq "60% remaining → no output (allow)" "" "$result"
cleanup_bridge

# ═══════════════════════════════════════════════════════════════
# 4. Caution tier (38% remaining) → advisory
# ═══════════════════════════════════════════════════════════════
printf "\n=== Caution Tier ===\n"

create_bridge 38
result=$(echo "$INPUT" | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_contains "Caution tier outputs CTX-CAUTION" "CTX-CAUTION" "$result"
assert_not_contains "Caution tier no deny" "deny" "$result"
cleanup_bridge

# ═══════════════════════════════════════════════════════════════
# 5. Warning tier (30% remaining) → advisory + signal
# ═══════════════════════════════════════════════════════════════
printf "\n=== Warning Tier ===\n"

create_bridge 30
result=$(echo "$INPUT" | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_contains "Warning tier outputs CTX-WARNING" "CTX-WARNING" "$result"

# Check that shutdown signal file was created
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$MOCK_CWD/tmp/.rune-shutdown-signal-${SESSION_ID}.json" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Shutdown signal file created at warning tier\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Shutdown signal file NOT created at warning tier\n"
fi
cleanup_bridge

# ═══════════════════════════════════════════════════════════════
# 6. Critical tier (20% remaining) → hard deny
# ═══════════════════════════════════════════════════════════════
printf "\n=== Critical Tier ===\n"

create_bridge 20
result=$(echo "$INPUT" | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
# Note: jq output has spaces after colons
assert_contains "Critical tier denies" '"permissionDecision": "deny"' "$result"
assert_contains "Critical tier mentions remaining" "20%" "$result"

# Check force shutdown signal
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if [[ -f "$MOCK_CWD/tmp/.rune-force-shutdown-${SESSION_ID}.json" ]]; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: Force shutdown signal created at critical tier\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: Force shutdown signal NOT created at critical tier\n"
fi
cleanup_bridge

# ═══════════════════════════════════════════════════════════════
# 7. Explore/Plan agent exemption
# ═══════════════════════════════════════════════════════════════
printf "\n=== Explore/Plan Exemption ===\n"

create_bridge 20  # Critical level
EXPLORE_INPUT=$(jq -n \
  --arg tool "Agent" \
  --arg subagent "Explore" \
  --arg cwd "$MOCK_CWD" \
  --arg sid "$SESSION_ID" \
  '{tool_name: $tool, tool_input: {subagent_type: $subagent}, cwd: $cwd, session_id: $sid}')

result=$(echo "$EXPLORE_INPUT" | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_eq "Explore agent exempt at critical → no output" "" "$result"

# Plan also exempt
PLAN_INPUT=$(jq -n \
  --arg tool "Task" \
  --arg subagent "Plan" \
  --arg cwd "$MOCK_CWD" \
  --arg sid "$SESSION_ID" \
  '{tool_name: $tool, tool_input: {subagent_type: $subagent}, cwd: $cwd, session_id: $sid}')
result=$(echo "$PLAN_INPUT" | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_eq "Plan agent exempt at critical → no output" "" "$result"

cleanup_bridge

# ═══════════════════════════════════════════════════════════════
# 8. Stale bridge → allow
# ═══════════════════════════════════════════════════════════════
printf "\n=== Stale Bridge ===\n"

# Create bridge with old FILE mtime (script checks file mtime, not JSON timestamp)
BRIDGE_FILE="/tmp/rune-ctx-${SESSION_ID}.json"
jq -n \
  --arg sid "$SESSION_ID" \
  --argjson rem 10 \
  --argjson used 90 \
  --argjson ts "$(($(date +%s) - 120))" \
  --arg cfg "$MOCK_CHOME" \
  --arg pid "NONE" \
  '{session_id: $sid, remaining_percentage: $rem, used_pct: $used, timestamp: $ts, config_dir: $cfg, owner_pid: $pid}' \
  > "$BRIDGE_FILE"
# Set file mtime to 2 minutes ago so script treats it as stale (>30s threshold)
touch -t "$(date -v-2M +%Y%m%d%H%M.%S)" "$BRIDGE_FILE"

result=$(echo "$INPUT" | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_eq "Stale bridge → no output (allow)" "" "$result"
cleanup_bridge

# ═══════════════════════════════════════════════════════════════
# 9. Symlink bridge → allow (ignored)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Symlink Bridge ===\n"

echo '{}' > "$TMP_DIR/fake-bridge.json"
ln -sf "$TMP_DIR/fake-bridge.json" "/tmp/rune-ctx-${SESSION_ID}.json"

result_code=0
result=$(echo "$INPUT" | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null) || result_code=$?
assert_eq "Symlink bridge → exit 0 (allow)" "0" "$result_code"
cleanup_bridge

# ═══════════════════════════════════════════════════════════════
# 10. Invalid session ID → exit 0
# ═══════════════════════════════════════════════════════════════
printf "\n=== Invalid Session ID ===\n"

BAD_INPUT=$(jq -n \
  --arg tool "TeamCreate" \
  --arg cwd "$MOCK_CWD" \
  --arg sid '../../../etc/passwd' \
  '{tool_name: $tool, cwd: $cwd, session_id: $sid}')

result_code=0
result=$(echo "$BAD_INPUT" | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null) || result_code=$?
assert_eq "Invalid session ID → exit 0" "0" "$result_code"

# ═══════════════════════════════════════════════════════════════
# 11. Non-Rune scope isolation (hook scope isolation)
# ═══════════════════════════════════════════════════════════════
printf "\n=== Non-Rune Scope Isolation ===\n"

# 11a. Non-Rune TeamCreate allowed at critical context
create_bridge 20
NONRUNE_TEAM_INPUT=$(jq -n \
  --arg tool "TeamCreate" \
  --arg cwd "$MOCK_CWD" \
  --arg sid "$SESSION_ID" \
  '{tool_name: $tool, tool_input: {team_name: "other-plugin-team-123", subagent_type: "general-purpose"}, cwd: $cwd, session_id: $sid}')
result=$(echo "$NONRUNE_TEAM_INPUT" | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_eq "Non-Rune TeamCreate at critical → no deny" "" "$result"
cleanup_bridge

# 11b. Rune TeamCreate still denied at critical context
create_bridge 20
RUNE_TEAM_INPUT=$(jq -n \
  --arg tool "TeamCreate" \
  --arg cwd "$MOCK_CWD" \
  --arg sid "$SESSION_ID" \
  '{tool_name: $tool, tool_input: {team_name: "rune-review-abc123", subagent_type: "general-purpose"}, cwd: $cwd, session_id: $sid}')
result=$(echo "$RUNE_TEAM_INPUT" | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_contains "Rune TeamCreate at critical → deny" '"permissionDecision": "deny"' "$result"
cleanup_bridge

# 11c. Non-Rune Agent allowed at critical context
create_bridge 20
NONRUNE_AGENT_INPUT=$(jq -n \
  --arg tool "Agent" \
  --arg cwd "$MOCK_CWD" \
  --arg sid "$SESSION_ID" \
  '{tool_name: $tool, tool_input: {name: "external-linter-agent", subagent_type: "general-purpose"}, cwd: $cwd, session_id: $sid}')
result=$(echo "$NONRUNE_AGENT_INPUT" | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_eq "Non-Rune Agent at critical → no deny" "" "$result"
cleanup_bridge

# 11d. Known Rune Agent still denied at critical context
create_bridge 20
RUNE_AGENT_INPUT=$(jq -n \
  --arg tool "Agent" \
  --arg cwd "$MOCK_CWD" \
  --arg sid "$SESSION_ID" \
  '{tool_name: $tool, tool_input: {name: "ward-sentinel", subagent_type: "general-purpose"}, cwd: $cwd, session_id: $sid}')
result=$(echo "$RUNE_AGENT_INPUT" | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_contains "Rune Agent at critical → deny" '"permissionDecision": "deny"' "$result"
cleanup_bridge

# ═══════════════════════════════════════════════════════════════
# 12. Teammate bypass
# ═══════════════════════════════════════════════════════════════
printf "\n=== Teammate Bypass ===\n"

create_bridge 10
TEAMMATE_INPUT=$(jq -n \
  --arg tool "TeamCreate" \
  --arg cwd "$MOCK_CWD" \
  --arg sid "$SESSION_ID" \
  --arg transcript "/path/to/subagents/ash-1/transcript.jsonl" \
  '{tool_name: $tool, tool_input: {subagent_type: "general-purpose"}, cwd: $cwd, session_id: $sid, transcript_path: $transcript}')

result=$(echo "$TEAMMATE_INPUT" | CLAUDE_CONFIG_DIR="$MOCK_CHOME" bash "$UNDER_TEST" 2>/dev/null)
assert_eq "Teammate transcript → bypass (allow)" "" "$result"
cleanup_bridge

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
