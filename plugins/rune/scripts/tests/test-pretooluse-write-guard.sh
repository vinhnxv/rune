#!/usr/bin/env bash
# test-pretooluse-write-guard.sh — Tests for scripts/lib/pretooluse-write-guard.sh
#
# Usage: bash plugins/rune/scripts/tests/test-pretooluse-write-guard.sh
# Exit: 0 on all pass, 1 on any failure.
#
# NOTE: Many guard functions call `exit 0` on failure (fail-open pattern).
# We test these by running them in subshells and checking exit codes + side effects.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/../lib" && pwd)"
SCRIPTS_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

# ── Temp directory for isolation ──
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# ── Mock environment ──
export CLAUDE_CONFIG_DIR="$TMP_DIR/config"
mkdir -p "$CLAUDE_CONFIG_DIR"
export CLAUDE_SESSION_ID="test-session-$$"

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

assert_contains() {
  local test_name="$1"
  local needle="$2"
  local haystack="$3"
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
  local test_name="$1"
  local needle="$2"
  local haystack="$3"
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

# Helper: Run a guard function in a subprocess with JSON input on stdin.
# Since guard functions call `exit 0` to bail out (fail-open), we run them
# in a subshell and capture the exit code.
# Args: $1 = function call (bash code), $2 = stdin JSON
# Returns: exit code of the subshell
_run_guard() {
  local func_code="$1"
  local stdin_json="${2:-}"
  local rc
  printf '%s' "$stdin_json" | bash -c "
    set -euo pipefail
    export CLAUDE_CONFIG_DIR=\"$CLAUDE_CONFIG_DIR\"
    export CLAUDE_SESSION_ID=\"$CLAUDE_SESSION_ID\"
    source \"$LIB_DIR/pretooluse-write-guard.sh\"
    $func_code
  " 2>/dev/null && rc=0 || rc=$?
  return $rc
}

# ═══════════════════════════════════════════════════════════════
# 1. rune_write_guard_preflight — tool name filtering
# ═══════════════════════════════════════════════════════════════
printf "\n=== rune_write_guard_preflight — tool filtering ===\n"

# 1a. Non-write tool exits 0 (allowed, bail out)
_run_guard "rune_write_guard_preflight" '{"tool_name":"Read","tool_input":{"file_path":"/foo.txt"}}' && rc=0 || rc=$?
assert_eq "Non-write tool (Read) bails out with exit 0" "0" "$rc"

# 1b. Bash tool exits 0 (not a write tool)
_run_guard "rune_write_guard_preflight" '{"tool_name":"Bash","tool_input":{"command":"ls"}}' && rc=0 || rc=$?
assert_eq "Bash tool bails out with exit 0" "0" "$rc"

# 1c. Empty tool name exits 0
_run_guard "rune_write_guard_preflight" '{"tool_name":"","tool_input":{}}' && rc=0 || rc=$?
assert_eq "Empty tool name bails out with exit 0" "0" "$rc"

# 1d. Write tool with empty file_path exits 0
_run_guard "rune_write_guard_preflight" '{"tool_name":"Write","tool_input":{"file_path":""}}' && rc=0 || rc=$?
assert_eq "Write with empty file_path bails out" "0" "$rc"

# 1e. Write tool without transcript_path exits 0 (not a subagent)
_run_guard "rune_write_guard_preflight" '{"tool_name":"Write","tool_input":{"file_path":"/foo.txt"}}' && rc=0 || rc=$?
assert_eq "Write without transcript_path (team-lead) bails out" "0" "$rc"

# 1f. Write tool with non-subagent transcript_path exits 0
_run_guard "rune_write_guard_preflight" '{"tool_name":"Write","tool_input":{"file_path":"/foo.txt"},"transcript_path":"/some/path/main"}' && rc=0 || rc=$?
assert_eq "Write with non-subagent transcript_path bails out" "0" "$rc"

# 1g. Edit tool recognized as write tool (does not bail on tool filter)
# This requires subagent transcript_path + valid CWD to pass all preflight gates
mkdir -p "$TMP_DIR/workdir"
_run_guard "rune_write_guard_preflight" "{\"tool_name\":\"Edit\",\"tool_input\":{\"file_path\":\"$TMP_DIR/workdir/foo.txt\"},\"transcript_path\":\"/path/subagents/agent1\",\"cwd\":\"$TMP_DIR/workdir\"}" && rc=0 || rc=$?
# Should succeed (exit 0 from function return, not bail-out) — all preflight checks pass
assert_eq "Edit tool passes preflight as subagent" "0" "$rc"

# 1h. NotebookEdit tool recognized
_run_guard "rune_write_guard_preflight" "{\"tool_name\":\"NotebookEdit\",\"tool_input\":{\"file_path\":\"$TMP_DIR/workdir/nb.ipynb\"},\"transcript_path\":\"/path/subagents/agent1\",\"cwd\":\"$TMP_DIR/workdir\"}" && rc=0 || rc=$?
assert_eq "NotebookEdit tool passes preflight" "0" "$rc"

# 1i. Write with subagent path and no CWD exits 0
_run_guard "rune_write_guard_preflight" '{"tool_name":"Write","tool_input":{"file_path":"/foo.txt"},"transcript_path":"/path/subagents/agent1"}' && rc=0 || rc=$?
assert_eq "Write with subagent path but no CWD bails out" "0" "$rc"

# ═══════════════════════════════════════════════════════════════
# 2. rune_find_active_state
# ═══════════════════════════════════════════════════════════════
printf "\n=== rune_find_active_state ===\n"

# Setup: create mock state files in CWD/tmp/
MOCK_CWD="$TMP_DIR/project"
mkdir -p "$MOCK_CWD/tmp"

# 2a. No state files -> exits 0 (bail out)
(
  set -euo pipefail
  source "$LIB_DIR/pretooluse-write-guard.sh"
  CWD="$MOCK_CWD"
  rune_find_active_state ".rune-work-*.json"
  echo "CONTINUED"
) 2>/dev/null && rc=0 || rc=$?
# Should exit 0 without printing CONTINUED (bails out)
result=$( (
  set -euo pipefail
  source "$LIB_DIR/pretooluse-write-guard.sh"
  CWD="$MOCK_CWD"
  rune_find_active_state ".rune-work-*.json"
  echo "CONTINUED"
) 2>/dev/null || true)
assert_not_contains "No state files: function bails out" "CONTINUED" "$result"

# 2b. State file with status != active -> exits 0
printf '{"status":"completed"}' > "$MOCK_CWD/tmp/.rune-work-test123.json"
result=$( (
  set -euo pipefail
  source "$LIB_DIR/pretooluse-write-guard.sh"
  CWD="$MOCK_CWD"
  rune_find_active_state ".rune-work-*.json"
  echo "CONTINUED"
) 2>/dev/null || true)
assert_not_contains "Non-active state file: function bails out" "CONTINUED" "$result"

# 2c. State file with status == active -> continues
printf '{"status":"active"}' > "$MOCK_CWD/tmp/.rune-work-test456.json"
result=$( (
  set -euo pipefail
  source "$LIB_DIR/pretooluse-write-guard.sh"
  CWD="$MOCK_CWD"
  rune_find_active_state ".rune-work-*.json"
  echo "STATE_FILE=$STATE_FILE"
) 2>/dev/null || true)
assert_contains "Active state file: function continues" "STATE_FILE=" "$result"
assert_contains "Active state file: correct path" ".rune-work-test456.json" "$result"

# Clean up state files
rm -f "$MOCK_CWD/tmp/.rune-work-"*.json

# ═══════════════════════════════════════════════════════════════
# 3. rune_extract_identifier
# ═══════════════════════════════════════════════════════════════
printf "\n=== rune_extract_identifier ===\n"

# 3a. Valid identifier extraction
result=$( (
  set -euo pipefail
  source "$LIB_DIR/pretooluse-write-guard.sh"
  rune_extract_identifier "/path/to/.rune-work-abc123.json" ".rune-work-"
  echo "ID=$IDENTIFIER"
) 2>/dev/null || true)
assert_contains "Valid identifier extracted" "ID=abc123" "$result"

# 3b. Identifier with hyphens and underscores
result=$( (
  set -euo pipefail
  source "$LIB_DIR/pretooluse-write-guard.sh"
  rune_extract_identifier "/path/to/.rune-work-my-task_01.json" ".rune-work-"
  echo "ID=$IDENTIFIER"
) 2>/dev/null || true)
assert_contains "Hyphen-underscore identifier extracted" "ID=my-task_01" "$result"

# 3c. Invalid identifier (contains dots) -> exits 0
result=$( (
  set -euo pipefail
  source "$LIB_DIR/pretooluse-write-guard.sh"
  rune_extract_identifier "/path/to/.rune-work-evil.path.json" ".rune-work-"
  echo "CONTINUED"
) 2>/dev/null || true)
assert_not_contains "Invalid identifier (dots) bails out" "CONTINUED" "$result"

# 3d. Identifier too long (>64 chars) -> exits 0
long_id=$(python3 -c "print('a' * 65)")
result=$( (
  set -euo pipefail
  source "$LIB_DIR/pretooluse-write-guard.sh"
  rune_extract_identifier "/path/to/.rune-work-${long_id}.json" ".rune-work-"
  echo "CONTINUED"
) 2>/dev/null || true)
assert_not_contains "Long identifier (>64) bails out" "CONTINUED" "$result"

# 3e. Identifier exactly 64 chars -> accepted
exact_id=$(python3 -c "print('b' * 64)")
result=$( (
  set -euo pipefail
  source "$LIB_DIR/pretooluse-write-guard.sh"
  rune_extract_identifier "/path/to/.rune-work-${exact_id}.json" ".rune-work-"
  echo "ID=$IDENTIFIER"
) 2>/dev/null || true)
assert_contains "64-char identifier accepted" "ID=${exact_id}" "$result"

# ═══════════════════════════════════════════════════════════════
# 4. rune_verify_session_ownership
# ═══════════════════════════════════════════════════════════════
printf "\n=== rune_verify_session_ownership ===\n"

# 4a. Own state file -> continues (same PID and config_dir)
own_state="$TMP_DIR/own-state.json"
jq -n --arg cfg "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" --argjson pid "$PPID" \
  '{config_dir:$cfg, owner_pid:($pid|tostring)}' > "$own_state"

result=$( (
  set -euo pipefail
  source "$LIB_DIR/pretooluse-write-guard.sh"
  CHOME="$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)"
  rune_verify_session_ownership "$own_state"
  echo "CONTINUED"
) 2>/dev/null || true)
assert_contains "Own state file: continues" "CONTINUED" "$result"

# 4b. Different config_dir -> exits 0 (skip)
diff_cfg_state="$TMP_DIR/diff-cfg-state.json"
jq -n --argjson pid "$PPID" \
  '{config_dir:"/different/config/dir", owner_pid:($pid|tostring)}' > "$diff_cfg_state"

result=$( (
  set -euo pipefail
  source "$LIB_DIR/pretooluse-write-guard.sh"
  CHOME="$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)"
  rune_verify_session_ownership "$diff_cfg_state"
  echo "CONTINUED"
) 2>/dev/null || true)
assert_not_contains "Different config_dir: bails out" "CONTINUED" "$result"

# 4c. Dead PID -> exits 0 (orphan, skip)
dead_pid_state="$TMP_DIR/dead-pid-state.json"
jq -n --arg cfg "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" \
  '{config_dir:$cfg, owner_pid:"99999"}' > "$dead_pid_state"

result=$( (
  set -euo pipefail
  source "$LIB_DIR/pretooluse-write-guard.sh"
  CHOME="$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)"
  rune_verify_session_ownership "$dead_pid_state"
  echo "CONTINUED"
) 2>/dev/null || true)
assert_not_contains "Dead PID: bails out" "CONTINUED" "$result"

# 4d. Live PID but different from PPID -> exits 0 (different session)
live_diff_state="$TMP_DIR/live-diff-state.json"
jq -n --arg cfg "$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)" --argjson pid "$$" \
  '{config_dir:$cfg, owner_pid:($pid|tostring)}' > "$live_diff_state"

result=$( (
  set -euo pipefail
  source "$LIB_DIR/pretooluse-write-guard.sh"
  CHOME="$(cd "$CLAUDE_CONFIG_DIR" && pwd -P)"
  rune_verify_session_ownership "$live_diff_state"
  echo "CONTINUED"
) 2>/dev/null || true)
# $$ (our PID) is alive and different from $PPID -> should bail
assert_not_contains "Live different PID: bails out" "CONTINUED" "$result"

# ═══════════════════════════════════════════════════════════════
# 5. rune_normalize_path
# ═══════════════════════════════════════════════════════════════
printf "\n=== rune_normalize_path ===\n"

# 5a. Absolute path relative to CWD
result=$( (
  set -euo pipefail
  source "$LIB_DIR/pretooluse-write-guard.sh"
  CWD="/home/user/project"
  FILE_PATH="/home/user/project/src/main.ts"
  rune_normalize_path
  echo "$REL_FILE_PATH"
) 2>/dev/null || true)
assert_eq "Absolute path made relative to CWD" "src/main.ts" "$result"

# 5b. Already relative path
result=$( (
  set -euo pipefail
  source "$LIB_DIR/pretooluse-write-guard.sh"
  CWD="/home/user/project"
  FILE_PATH="src/main.ts"
  rune_normalize_path
  echo "$REL_FILE_PATH"
) 2>/dev/null || true)
assert_eq "Relative path passes through" "src/main.ts" "$result"

# 5c. Path with leading ./
result=$( (
  set -euo pipefail
  source "$LIB_DIR/pretooluse-write-guard.sh"
  CWD="/home/user/project"
  FILE_PATH="./src/main.ts"
  rune_normalize_path
  echo "$REL_FILE_PATH"
) 2>/dev/null || true)
assert_eq "Leading ./ stripped" "src/main.ts" "$result"

# 5d. Custom path parameter overrides FILE_PATH
result=$( (
  set -euo pipefail
  source "$LIB_DIR/pretooluse-write-guard.sh"
  CWD="/home/user/project"
  FILE_PATH="should-not-use.txt"
  rune_normalize_path "/home/user/project/override/file.ts"
  echo "$REL_FILE_PATH"
) 2>/dev/null || true)
assert_eq "Custom path parameter used" "override/file.ts" "$result"

# 5e. Path outside CWD preserved as-is
result=$( (
  set -euo pipefail
  source "$LIB_DIR/pretooluse-write-guard.sh"
  CWD="/home/user/project"
  FILE_PATH="/other/location/file.txt"
  rune_normalize_path
  echo "$REL_FILE_PATH"
) 2>/dev/null || true)
assert_eq "Path outside CWD preserved" "/other/location/file.txt" "$result"

# ═══════════════════════════════════════════════════════════════
# 6. rune_deny_write
# ═══════════════════════════════════════════════════════════════
printf "\n=== rune_deny_write ===\n"

# 6a. Produces valid JSON with correct fields
result=$( (
  set -euo pipefail
  source "$LIB_DIR/pretooluse-write-guard.sh"
  rune_deny_write "SEC-TEST-001: Test denial" "Additional context here"
) 2>/dev/null || true)

# Validate JSON structure
TOTAL_COUNT=$(( TOTAL_COUNT + 1 ))
if printf '%s' "$result" | jq -e '.hookSpecificOutput.hookEventName == "PreToolUse"' >/dev/null 2>&1; then
  PASS_COUNT=$(( PASS_COUNT + 1 ))
  printf "  PASS: deny_write JSON has hookEventName=PreToolUse\n"
else
  FAIL_COUNT=$(( FAIL_COUNT + 1 ))
  printf "  FAIL: deny_write JSON missing hookEventName\n"
fi

# 6b. Permission decision is "deny"
decision=$(printf '%s' "$result" | jq -r '.hookSpecificOutput.permissionDecision' 2>/dev/null || echo "")
assert_eq "deny_write permissionDecision=deny" "deny" "$decision"

# 6c. Reason field present
reason=$(printf '%s' "$result" | jq -r '.hookSpecificOutput.permissionDecisionReason' 2>/dev/null || echo "")
assert_contains "deny_write reason contains SEC code" "SEC-TEST-001" "$reason"

# 6d. Additional context field present
ctx=$(printf '%s' "$result" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null || echo "")
assert_eq "deny_write additionalContext" "Additional context here" "$ctx"

# 6e. deny_write exits 0 (so the hook doesn't fail)
printf '' | bash -c "
  set -euo pipefail
  source \"$LIB_DIR/pretooluse-write-guard.sh\"
  rune_deny_write 'test' 'ctx'
" >/dev/null 2>&1 && rc=0 || rc=$?
assert_eq "deny_write exits 0" "0" "$rc"

# ═══════════════════════════════════════════════════════════════
# 7. rune_write_guard_preflight — stdin 1MB cap
# ═══════════════════════════════════════════════════════════════
printf "\n=== rune_write_guard_preflight — input handling ===\n"

# 7a. Empty stdin bails out gracefully
_run_guard "rune_write_guard_preflight" "" && rc=0 || rc=$?
assert_eq "Empty stdin bails out" "0" "$rc"

# 7b. Invalid JSON bails out gracefully
_run_guard "rune_write_guard_preflight" "not json at all" && rc=0 || rc=$?
assert_eq "Invalid JSON bails out" "0" "$rc"

# 7c. JSON without tool_name bails out
_run_guard "rune_write_guard_preflight" '{"tool_input":{"file_path":"/foo"}}' && rc=0 || rc=$?
assert_eq "Missing tool_name bails out" "0" "$rc"

# ═══════════════════════════════════════════════════════════════
# 8. Integration: full preflight with subagent context
# ═══════════════════════════════════════════════════════════════
printf "\n=== Integration: preflight subagent context ===\n"

# 8a. Subagent Write with valid CWD completes preflight
mkdir -p "$TMP_DIR/test-project"
input_json=$(jq -n \
  --arg tool "Write" \
  --arg fp "$TMP_DIR/test-project/src/file.ts" \
  --arg tp "/transcript/subagents/worker1" \
  --arg cwd "$TMP_DIR/test-project" \
  '{tool_name:$tool, tool_input:{file_path:$fp}, transcript_path:$tp, cwd:$cwd}')

result=$(printf '%s' "$input_json" | bash -c "
  set -euo pipefail
  export CLAUDE_CONFIG_DIR=\"$CLAUDE_CONFIG_DIR\"
  export CLAUDE_SESSION_ID=\"$CLAUDE_SESSION_ID\"
  source \"$LIB_DIR/pretooluse-write-guard.sh\"
  rune_write_guard_preflight 'test'
  echo \"TOOL=\$TOOL_NAME FILE=\$FILE_PATH CWD=\$CWD\"
" 2>/dev/null || true)
assert_contains "Subagent preflight: TOOL extracted" "TOOL=Write" "$result"
assert_contains "Subagent preflight: FILE extracted" "FILE=$TMP_DIR/test-project/src/file.ts" "$result"

# 8b. Non-subagent Write skips (team-lead exempt)
input_json=$(jq -n \
  --arg tool "Write" \
  --arg fp "$TMP_DIR/test-project/src/file.ts" \
  --arg tp "/transcript/main" \
  --arg cwd "$TMP_DIR/test-project" \
  '{tool_name:$tool, tool_input:{file_path:$fp}, transcript_path:$tp, cwd:$cwd}')

result=$(printf '%s' "$input_json" | bash -c "
  set -euo pipefail
  export CLAUDE_CONFIG_DIR=\"$CLAUDE_CONFIG_DIR\"
  export CLAUDE_SESSION_ID=\"$CLAUDE_SESSION_ID\"
  source \"$LIB_DIR/pretooluse-write-guard.sh\"
  rune_write_guard_preflight 'test'
  echo 'CONTINUED'
" 2>/dev/null || true)
assert_not_contains "Non-subagent Write: bails (team-lead exempt)" "CONTINUED" "$result"

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
