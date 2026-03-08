#!/usr/bin/env bash
# test-enforce-readonly.sh — Tests for scripts/enforce-readonly.sh
#
# Usage: bash plugins/rune/scripts/tests/test-enforce-readonly.sh
# Exit: 0 on all pass, 1 on any failure.

set -euo pipefail

# ── Resolve paths ──
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENFORCE_SCRIPT="$(cd "$SCRIPT_DIR/.." && pwd)/enforce-readonly.sh"

# ── Temp workspace ──
TMPWORK=$(mktemp -d)
trap 'rm -rf "$TMPWORK"' EXIT

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

# Helper: run the script with given JSON on stdin
run_hook() {
  local json="$1"
  local output
  local rc=0
  output=$(printf '%s' "$json" | bash "$ENFORCE_SCRIPT" 2>/dev/null) || rc=$?
  printf '%s\n%d' "$output" "$rc"
}

get_output() {
  local result="$1"
  printf '%s' "$result" | sed '$d'
}

get_exit_code() {
  local result="$1"
  printf '%s' "$result" | tail -1
}

# ═══════════════════════════════════════════════════════════════
# 1. Non-subagent (team lead) — always allowed
# ═══════════════════════════════════════════════════════════════
printf "\n=== Non-Subagent (Team Lead) ===\n"

# 1a. No transcript_path — treated as team lead
result=$(run_hook '{"tool_name": "Write", "cwd": "/tmp", "tool_input": {"file_path": "/tmp/test.txt"}}')
assert_eq "No transcript_path exits 0" "0" "$(get_exit_code "$result")"
assert_eq "No transcript_path no output" "" "$(get_output "$result")"

# 1b. transcript_path without /subagents/ — team lead
result=$(run_hook '{"tool_name": "Write", "cwd": "/tmp", "transcript_path": "/home/user/.claude/sessions/abc123/transcript.jsonl", "tool_input": {}}')
assert_eq "Team lead transcript exits 0" "0" "$(get_exit_code "$result")"
assert_eq "Team lead transcript no output" "" "$(get_output "$result")"

# 1c. Empty transcript_path
result=$(run_hook '{"tool_name": "Write", "cwd": "/tmp", "transcript_path": "", "tool_input": {}}')
assert_eq "Empty transcript exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 2. Subagent WITHOUT readonly marker — allowed
# ═══════════════════════════════════════════════════════════════
printf "\n=== Subagent Without Readonly Marker ===\n"

NOCWD="$TMPWORK/no-readonly"
mkdir -p "$NOCWD/tmp/.rune-signals"

# 2a. Subagent, no signal dirs at all
result=$(run_hook "{\"tool_name\": \"Write\", \"cwd\": \"$NOCWD\", \"transcript_path\": \"/home/.claude/sessions/abc/subagents/agent1/transcript.jsonl\", \"tool_input\": {}}")
assert_eq "No signal dirs exits 0" "0" "$(get_exit_code "$result")"
assert_eq "No signal dirs no output" "" "$(get_output "$result")"

# 2b. Subagent with signal dir but NO .readonly-active marker
mkdir -p "$NOCWD/tmp/.rune-signals/rune-review-abc123"
result=$(run_hook "{\"tool_name\": \"Write\", \"cwd\": \"$NOCWD\", \"transcript_path\": \"/home/.claude/sessions/abc/subagents/agent1/transcript.jsonl\", \"tool_input\": {}}")
assert_eq "No marker exits 0" "0" "$(get_exit_code "$result")"
assert_eq "No marker no output" "" "$(get_output "$result")"

# ═══════════════════════════════════════════════════════════════
# 3. Subagent WITH readonly marker — DENY
# ═══════════════════════════════════════════════════════════════
printf "\n=== Subagent With Readonly Marker (DENY) ===\n"

ROCWD="$TMPWORK/readonly-project"
mkdir -p "$ROCWD/tmp/.rune-signals/rune-review-abc123"
touch "$ROCWD/tmp/.rune-signals/rune-review-abc123/.readonly-active"

# 3a. Write tool blocked for subagent
result=$(run_hook "{\"tool_name\": \"Write\", \"cwd\": \"$ROCWD\", \"transcript_path\": \"/home/.claude/sessions/abc/subagents/agent1/transcript.jsonl\", \"tool_input\": {}}")
assert_eq "Write blocked exits 0" "0" "$(get_exit_code "$result")"
output=$(get_output "$result")
assert_contains "Write blocked has deny" '"permissionDecision":"deny"' "$output"
assert_contains "Write blocked has SEC-001" "SEC-001" "$output"
assert_contains "Write blocked has hookEventName" '"hookEventName":"PreToolUse"' "$output"

# 3b. Edit tool blocked for subagent
result=$(run_hook "{\"tool_name\": \"Edit\", \"cwd\": \"$ROCWD\", \"transcript_path\": \"/home/.claude/sessions/abc/subagents/agent1/transcript.jsonl\", \"tool_input\": {}}")
output=$(get_output "$result")
assert_contains "Edit blocked has deny" '"permissionDecision":"deny"' "$output"

# 3c. Bash tool blocked for subagent
result=$(run_hook "{\"tool_name\": \"Bash\", \"cwd\": \"$ROCWD\", \"transcript_path\": \"/home/.claude/sessions/abc/subagents/agent1/transcript.jsonl\", \"tool_input\": {}}")
output=$(get_output "$result")
assert_contains "Bash blocked has deny" '"permissionDecision":"deny"' "$output"

# 3d. NotebookEdit tool blocked for subagent
result=$(run_hook "{\"tool_name\": \"NotebookEdit\", \"cwd\": \"$ROCWD\", \"transcript_path\": \"/home/.claude/sessions/abc/subagents/agent1/transcript.jsonl\", \"tool_input\": {}}")
output=$(get_output "$result")
assert_contains "NotebookEdit blocked has deny" '"permissionDecision":"deny"' "$output"

# 3e. Team lead NOT blocked even with readonly marker
result=$(run_hook "{\"tool_name\": \"Write\", \"cwd\": \"$ROCWD\", \"transcript_path\": \"/home/.claude/sessions/abc/transcript.jsonl\", \"tool_input\": {}}")
assert_eq "Team lead not blocked exits 0" "0" "$(get_exit_code "$result")"
assert_eq "Team lead not blocked no output" "" "$(get_output "$result")"

# ═══════════════════════════════════════════════════════════════
# 4. Multiple signal directory types
# ═══════════════════════════════════════════════════════════════
printf "\n=== Multiple Signal Directory Types ===\n"

# 4a. arc-review-* signal
ARCCWD="$TMPWORK/arc-review-project"
mkdir -p "$ARCCWD/tmp/.rune-signals/arc-review-xyz"
touch "$ARCCWD/tmp/.rune-signals/arc-review-xyz/.readonly-active"
result=$(run_hook "{\"tool_name\": \"Write\", \"cwd\": \"$ARCCWD\", \"transcript_path\": \"/subagents/a/t.jsonl\", \"tool_input\": {}}")
output=$(get_output "$result")
assert_contains "arc-review blocked" "SEC-001" "$output"

# 4b. rune-audit-* signal
AUDITCWD="$TMPWORK/audit-project"
mkdir -p "$AUDITCWD/tmp/.rune-signals/rune-audit-abc"
touch "$AUDITCWD/tmp/.rune-signals/rune-audit-abc/.readonly-active"
result=$(run_hook "{\"tool_name\": \"Write\", \"cwd\": \"$AUDITCWD\", \"transcript_path\": \"/subagents/a/t.jsonl\", \"tool_input\": {}}")
output=$(get_output "$result")
assert_contains "rune-audit blocked" "SEC-001" "$output"

# 4c. arc-audit-* signal
ARCAUDITCWD="$TMPWORK/arc-audit-project"
mkdir -p "$ARCAUDITCWD/tmp/.rune-signals/arc-audit-def"
touch "$ARCAUDITCWD/tmp/.rune-signals/arc-audit-def/.readonly-active"
result=$(run_hook "{\"tool_name\": \"Write\", \"cwd\": \"$ARCAUDITCWD\", \"transcript_path\": \"/subagents/a/t.jsonl\", \"tool_input\": {}}")
output=$(get_output "$result")
assert_contains "arc-audit blocked" "SEC-001" "$output"

# 4d. rune-inspect-* signal
INSPECTCWD="$TMPWORK/inspect-project"
mkdir -p "$INSPECTCWD/tmp/.rune-signals/rune-inspect-ghi"
touch "$INSPECTCWD/tmp/.rune-signals/rune-inspect-ghi/.readonly-active"
result=$(run_hook "{\"tool_name\": \"Write\", \"cwd\": \"$INSPECTCWD\", \"transcript_path\": \"/subagents/a/t.jsonl\", \"tool_input\": {}}")
output=$(get_output "$result")
assert_contains "rune-inspect blocked" "SEC-001" "$output"

# 4e. rune-work-* (NOT review/audit) should NOT block even with marker
WORKCWD="$TMPWORK/work-project"
mkdir -p "$WORKCWD/tmp/.rune-signals/rune-work-abc"
touch "$WORKCWD/tmp/.rune-signals/rune-work-abc/.readonly-active"
result=$(run_hook "{\"tool_name\": \"Write\", \"cwd\": \"$WORKCWD\", \"transcript_path\": \"/subagents/a/t.jsonl\", \"tool_input\": {}}")
assert_eq "Work team not blocked exits 0" "0" "$(get_exit_code "$result")"
assert_eq "Work team not blocked no output" "" "$(get_output "$result")"

# 4f. rune-mend-* (NOT review/audit) should NOT block
MENDCWD="$TMPWORK/mend-project"
mkdir -p "$MENDCWD/tmp/.rune-signals/rune-mend-abc"
touch "$MENDCWD/tmp/.rune-signals/rune-mend-abc/.readonly-active"
result=$(run_hook "{\"tool_name\": \"Write\", \"cwd\": \"$MENDCWD\", \"transcript_path\": \"/subagents/a/t.jsonl\", \"tool_input\": {}}")
assert_eq "Mend team not blocked exits 0" "0" "$(get_exit_code "$result")"
assert_eq "Mend team not blocked no output" "" "$(get_output "$result")"

# ═══════════════════════════════════════════════════════════════
# 5. No signals directory at all
# ═══════════════════════════════════════════════════════════════
printf "\n=== No Signals Directory ===\n"

NOSIGCWD="$TMPWORK/no-signals"
mkdir -p "$NOSIGCWD/tmp"

# 5a. Subagent with no .rune-signals dir
result=$(run_hook "{\"tool_name\": \"Write\", \"cwd\": \"$NOSIGCWD\", \"transcript_path\": \"/subagents/a/t.jsonl\", \"tool_input\": {}}")
assert_eq "No signals dir exits 0" "0" "$(get_exit_code "$result")"
assert_eq "No signals dir no output" "" "$(get_output "$result")"

# ═══════════════════════════════════════════════════════════════
# 6. CWD handling
# ═══════════════════════════════════════════════════════════════
printf "\n=== CWD Handling ===\n"

# 6a. Empty CWD — subagent path (should allow, CWD guard)
result=$(run_hook '{"tool_name": "Write", "cwd": "", "transcript_path": "/subagents/a/t.jsonl", "tool_input": {}}')
assert_eq "Empty CWD exits 0" "0" "$(get_exit_code "$result")"

# 6b. Missing CWD
result=$(run_hook '{"tool_name": "Write", "transcript_path": "/subagents/a/t.jsonl", "tool_input": {}}')
assert_eq "Missing CWD exits 0" "0" "$(get_exit_code "$result")"

# 6c. Invalid CWD
result=$(run_hook '{"tool_name": "Write", "cwd": "/nonexistent/path", "transcript_path": "/subagents/a/t.jsonl", "tool_input": {}}')
assert_eq "Invalid CWD exits 0" "0" "$(get_exit_code "$result")"

# ═══════════════════════════════════════════════════════════════
# 7. SECURITY hook — fail-closed behavior
# ═══════════════════════════════════════════════════════════════
printf "\n=== Security Hook Behavior ===\n"

# 7a. This is a SECURITY hook — no ERR trap, no fail-forward
# The script has NO _rune_fail_forward. If jq is missing, it exits 2 (blocking).
# We can't easily test jq-missing, but we can verify the script's exit behavior
# is consistent with its security classification.

# Verify the script always exits 0 for valid JSON (not exit 2)
result=$(run_hook '{"tool_name": "Write", "cwd": "/tmp", "tool_input": {}}')
assert_eq "Valid JSON exits 0 (not 2)" "0" "$(get_exit_code "$result")"

# 7b. Test that invalid signal dir names are rejected (SEC-4)
# Directory name that doesn't match the regex
BADSIGCWD="$TMPWORK/bad-signal-name"
mkdir -p "$BADSIGCWD/tmp/.rune-signals/invalid-name-!!!"
touch "$BADSIGCWD/tmp/.rune-signals/invalid-name-!!!/.readonly-active"
result=$(run_hook "{\"tool_name\": \"Write\", \"cwd\": \"$BADSIGCWD\", \"transcript_path\": \"/subagents/a/t.jsonl\", \"tool_input\": {}}")
assert_eq "Invalid signal dir name exits 0" "0" "$(get_exit_code "$result")"
assert_eq "Invalid signal dir name no deny" "" "$(get_output "$result")"

# ═══════════════════════════════════════════════════════════════
# 8. Edge cases
# ═══════════════════════════════════════════════════════════════
printf "\n=== Edge Cases ===\n"

# 8a. Empty stdin
result=$(printf '' | bash "$ENFORCE_SCRIPT" 2>/dev/null; echo $?)
assert_eq "Empty stdin exits 0" "0" "$result"

# 8b. Invalid JSON
result=$(printf 'garbage' | bash "$ENFORCE_SCRIPT" 2>/dev/null; echo $?)
assert_eq "Invalid JSON exits 0" "0" "$result"

# 8c. Deeply nested subagent path
result=$(run_hook "{\"tool_name\": \"Write\", \"cwd\": \"$ROCWD\", \"transcript_path\": \"/deep/path/subagents/nested/subagents/agent/transcript.jsonl\", \"tool_input\": {}}")
output=$(get_output "$result")
assert_contains "Deep subagent path blocked" "SEC-001" "$output"

# 8d. Read tool — should NOT be blocked (not Write/Edit/Bash/NotebookEdit)
# Note: enforce-readonly.sh checks transcript_path for subagent detection,
# but the hook matcher only fires for Write|Edit|Bash|NotebookEdit.
# However, the script itself doesn't filter by tool_name — that's done by the matcher.
# So if called with Read, it would still block if subagent+readonly.
# This is fine because the hooks.json matcher prevents this call for Read.
result=$(run_hook "{\"tool_name\": \"Read\", \"cwd\": \"$ROCWD\", \"transcript_path\": \"/subagents/a/t.jsonl\", \"tool_input\": {}}")
# The script itself would deny it (it doesn't filter tool_name),
# but in practice this would never be called for Read due to hooks.json matcher.
# We test the script's behavior directly.
output=$(get_output "$result")
assert_contains "Read tool also blocked by script" "SEC-001" "$output"

# ═══════════════════════════════════════════════════════════════
# 9. Two-phase ERR trap behavior
# ═══════════════════════════════════════════════════════════════
printf "\n=== Two-Phase ERR Trap ===\n"

# 9a. Fast-path (non-subagent) should exit 0 even on unexpected errors
# The fail-forward ERR trap covers the fast-path before subagent detection.
# This test verifies that edge cases in the fast-path don't produce exit 1 ("hook error").
result=$(printf '{"tool_name":"Bash","cwd":"/nonexistent/path","tool_input":{"command":"echo hi"}}' | bash "$ENFORCE_SCRIPT" 2>/dev/null; echo $?)
assert_eq "Non-subagent with bad CWD exits 0 (not hook error)" "0" "$result"

# 9b. Non-subagent with malformed transcript_path should still exit 0
result=$(printf '{"tool_name":"Bash","cwd":"/tmp","transcript_path":null,"tool_input":{"command":"echo hi"}}' | bash "$ENFORCE_SCRIPT" 2>/dev/null; echo $?)
assert_eq "Null transcript_path exits 0" "0" "$result"

# 9c. Non-subagent with missing tool_input should exit 0
result=$(printf '{"tool_name":"Bash","cwd":"/tmp"}' | bash "$ENFORCE_SCRIPT" 2>/dev/null; echo $?)
assert_eq "Missing tool_input exits 0" "0" "$result"

# 9d. Subagent with missing CWD should exit 0 or 2 (fail-closed after subagent detection)
result=$(printf '{"tool_name":"Bash","transcript_path":"/subagents/a/t.jsonl","tool_input":{"command":"echo hi"}}' | bash "$ENFORCE_SCRIPT" 2>/dev/null; echo $?)
assert_eq "Subagent with missing CWD exits 0" "0" "$result"

# 9e. Subagent with inaccessible CWD should not produce exit 1 (hook error)
result=$(printf '{"tool_name":"Bash","cwd":"/nonexistent/restricted","transcript_path":"/subagents/a/t.jsonl","tool_input":{"command":"echo hi"}}' | bash "$ENFORCE_SCRIPT" 2>/dev/null; echo $?)
# Should exit 0 (CWD cd fails, caught by || { exit 0; })
assert_eq "Subagent with bad CWD exits 0" "0" "$result"

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
